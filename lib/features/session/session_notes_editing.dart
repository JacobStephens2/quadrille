import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import 'data/session_repository.dart';
import 'session_providers.dart';

enum SessionNotesEditingState { idle, pending, succeeded, failed, superseded }

/// Retains the invoking Local profile generation and exact notes destination.
/// Capture from the rendering scope, independently of screen subscriptions.
class SessionNotesEditing {
  SessionNotesEditing._(this._ref, this._generation, this._repository) {
    _generation.addListener(_retire);
  }

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final SessionRepository _repository;
  final _openings = <SessionNotesOpening>{};
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

  SessionNotesOpening edit(WorkoutSession session) =>
      SessionNotesOpening._(this, session.id, session.generalNotes ?? '');

  void _retire() {
    if (!_active) return;
    _active = false;
    _generation.removeListener(_retire);
    for (final opening in _openings.toList()) {
      opening._supersede();
    }
  }
}

final sessionNotesEditingProvider = Provider<SessionNotesEditing>((ref) {
  final editing = SessionNotesEditing._(
    ref,
    ref.watch(localProfileGenerationProvider),
    ref.watch(sessionRepositoryProvider),
  );
  ref.onDispose(editing._retire);
  return editing;
});

/// One fixed workout snapshot, with independent save admission and feedback.
class SessionNotesOpening extends ChangeNotifier {
  SessionNotesOpening._(this._owner, this.sessionId, this.initialNotes) {
    if (_owner._isCurrent) {
      _owner._openings.add(this);
    } else {
      _state = SessionNotesEditingState.superseded;
    }
  }

  final SessionNotesEditing _owner;
  final String sessionId;
  final String initialNotes;
  SessionNotesEditingState _state = SessionNotesEditingState.idle;
  Future<SessionNotesEditingState>? _pending;
  bool _released = false;

  SessionNotesEditingState get state =>
      isCurrent ? _state : SessionNotesEditingState.superseded;
  bool get isCurrent =>
      !_released &&
      _state != SessionNotesEditingState.superseded &&
      _owner._isCurrent;
  bool get canSubmit =>
      isCurrent &&
      (_state == SessionNotesEditingState.idle ||
          _state == SessionNotesEditingState.failed);
  String? get errorMessage => state == SessionNotesEditingState.failed
      ? 'Could not save notes. Please try again.'
      : null;

  void _supersede() {
    _state = SessionNotesEditingState.superseded;
    _owner._openings.remove(this);
    // Retirement may happen during provider/widget teardown. Eligibility is
    // synchronous; defer only observation until presentation can rebuild.
    scheduleMicrotask(() {
      if (!_released) notifyListeners();
    });
  }

  /// Rejects new saves and late observation without cancelling accepted writes.
  void release() => dispose();

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _state = SessionNotesEditingState.superseded;
    _owner._openings.remove(this);
    super.dispose();
  }

  Future<SessionNotesEditingState> save(String notes) {
    if (!isCurrent) return Future.value(SessionNotesEditingState.superseded);
    if (_pending != null) return _pending!;
    if (_state == SessionNotesEditingState.succeeded) {
      return Future.value(_state);
    }
    final completion = Completer<SessionNotesEditingState>();
    _pending = completion.future;
    _state = SessionNotesEditingState.pending;
    // Claim the future and immutable text before listeners can reenter.
    notifyListeners();
    unawaited(_persist(notes, completion));
    return completion.future;
  }

  Future<void> _persist(
    String notes,
    Completer<SessionNotesEditingState> completion,
  ) async {
    var result = SessionNotesEditingState.superseded;
    try {
      // Submission accepts the write. Later retirement/release can supersede
      // feedback but cannot redirect or cancel this captured persistence.
      if (isCurrent) {
        await _owner._repository.setSessionNotes(sessionId, notes);
        if (isCurrent) result = SessionNotesEditingState.succeeded;
      }
    } catch (_) {
      if (isCurrent) result = SessionNotesEditingState.failed;
    }
    _pending = null;
    _state = result;
    completion.complete(result);
    if (!_released) notifyListeners();
  }
}
