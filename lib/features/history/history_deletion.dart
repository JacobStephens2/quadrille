import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../session/data/session_repository.dart';
import '../session/session_providers.dart';

enum HistoryDeletionState {
  idle,
  pending,
  deleted,
  unavailable,
  failed,
  superseded,
}

/// Retains one Local profile generation and its exact Session destination.
class HistoryDeletion {
  HistoryDeletion._(this._ref, this._generation, this._repository) {
    _generation.addListener(_retire);
  }

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final SessionRepository _repository;
  final _openings = <HistoryDeletionOpening>{};
  bool _active = true;

  bool get _isCurrent {
    if (!_active) return false;
    if (!_ref.mounted ||
        !_generation.isCurrent ||
        !identical(_repository, _ref.read(sessionRepositoryProvider))) {
      _retire();
    }
    return _active;
  }

  HistoryDeletionOpening open(WorkoutSession workout) =>
      HistoryDeletionOpening._(
        this,
        workout.id,
        workout.name,
        workout.startedAt,
      );

  void _retire() {
    if (!_active) return;
    _active = false;
    _generation.removeListener(_retire);
    for (final opening in _openings.toList()) {
      opening._supersede();
    }
  }
}

final historyDeletionProvider = Provider<HistoryDeletion>((ref) {
  final deletion = HistoryDeletion._(
    ref,
    ref.watch(localProfileGenerationProvider),
    ref.watch(sessionRepositoryProvider),
  );
  ref.onDispose(deletion._retire);
  return deletion;
});

/// One confirmation's immutable target, observable state and deletion authority.
class HistoryDeletionOpening extends ChangeNotifier {
  HistoryDeletionOpening._(
    this._owner,
    this.sessionId,
    this.name,
    this.startedAt,
  ) {
    if (_owner._isCurrent) {
      _owner._openings.add(this);
    } else {
      _state = HistoryDeletionState.superseded;
    }
  }

  final HistoryDeletion _owner;
  final String sessionId;
  final String name;
  final DateTime startedAt;
  HistoryDeletionState _state = HistoryDeletionState.idle;
  Future<HistoryDeletionState>? _pending;
  bool _released = false;

  HistoryDeletionState get state =>
      isCurrent ? _state : HistoryDeletionState.superseded;
  bool get isCurrent =>
      !_released &&
      _state != HistoryDeletionState.superseded &&
      _owner._isCurrent;
  bool get canSubmit =>
      isCurrent &&
      (_state == HistoryDeletionState.idle ||
          _state == HistoryDeletionState.failed);

  void _supersede() {
    _state = HistoryDeletionState.superseded;
    _owner._openings.remove(this);
    // Authority retires synchronously; observation waits past provider teardown.
    scheduleMicrotask(() {
      if (!_released) notifyListeners();
    });
  }

  /// Rejects new deletion without cancelling persistence already admitted.
  void release() => dispose();

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _state = HistoryDeletionState.superseded;
    _owner._openings.remove(this);
    // A pending listener may release this opening during notifyListeners.
    scheduleMicrotask(super.dispose);
  }

  Future<HistoryDeletionState> delete() {
    if (!isCurrent) return Future.value(HistoryDeletionState.superseded);
    if (_pending != null) return _pending!;
    if (!canSubmit) return Future.value(_state);
    final completion = Completer<HistoryDeletionState>();
    _pending = completion.future;
    _state = HistoryDeletionState.pending;
    // Claim the future before notifying listeners that may reenter or retire us.
    notifyListeners();
    unawaited(_persist(completion));
    return completion.future;
  }

  Future<void> _persist(Completer<HistoryDeletionState> completion) async {
    var result = HistoryDeletionState.superseded;
    try {
      // Invocation accepts persistence in this destination. Later retirement or
      // release supersedes feedback, never redirects or cancels that write.
      if (isCurrent) {
        final deleted = await _owner._repository.deleteCompletedSession(
          sessionId,
        );
        if (isCurrent) {
          result = deleted
              ? HistoryDeletionState.deleted
              : HistoryDeletionState.unavailable;
        }
      }
    } catch (_) {
      if (isCurrent) result = HistoryDeletionState.failed;
    }
    _pending = null;
    _state = result;
    completion.complete(result);
    if (!_released) notifyListeners();
  }
}
