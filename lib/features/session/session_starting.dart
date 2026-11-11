import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'data/session_repository.dart';
import 'session_providers.dart';

enum SessionStartingStatus { started, failed, superseded }

class SessionStartingOutcome {
  const SessionStartingOutcome.started(this.sessionId)
    : status = SessionStartingStatus.started,
      error = null;
  const SessionStartingOutcome.failed(this.error)
    : status = SessionStartingStatus.failed,
      sessionId = null;
  const SessionStartingOutcome.superseded()
    : status = SessionStartingStatus.superseded,
      sessionId = null,
      error = null;

  final SessionStartingStatus status;
  final String? sessionId;
  final Object? error;
}

/// Retain the exact invoked handle across the await, including in callers that
/// keep their navigation stack alive. Only pending starts are shared.
class SessionStartingHandle extends ChangeNotifier {
  SessionStartingHandle._(
    this._ref,
    this._generation,
    this._repository,
    this.templateId,
  );

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final SessionRepository _repository;
  final String templateId;
  Future<SessionStartingOutcome>? _pending;
  bool _disposed = false;

  bool get isCurrent =>
      !_disposed &&
      _ref.mounted &&
      _generation.isCurrent &&
      identical(_ref.read(sessionRepositoryProvider), _repository);
  bool get isPending => _pending != null;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<SessionStartingOutcome> start() {
    if (_pending case final pending?) return pending;
    if (!isCurrent) {
      return Future.value(const SessionStartingOutcome.superseded());
    }

    // Claim before listeners or persistence can re-enter, even synchronously.
    final completion = Completer<SessionStartingOutcome>();
    _pending = completion.future;
    notifyListeners();
    unawaited(() async {
      final result = await _run();
      final outcome = isCurrent
          ? result
          : const SessionStartingOutcome.superseded();
      _pending = null;
      if (!_disposed) notifyListeners();
      completion.complete(outcome);
    }());
    return completion.future;
  }

  Future<SessionStartingOutcome> _run() async {
    try {
      // Submission accepts persistence into this exact repository. Retirement
      // after submission changes the outcome, never the transaction's target.
      if (!isCurrent) return const SessionStartingOutcome.superseded();
      final id = await _repository.startFromTemplate(templateId);
      return SessionStartingOutcome.started(id);
    } catch (error) {
      return SessionStartingOutcome.failed(error);
    }
  }
}

/// Kept independently of screen subscriptions; dependency disposal permanently
/// retires handles while accepted transactions settle using captured objects.
final sessionStartingProvider = Provider.family<SessionStartingHandle, String>((
  ref,
  templateId,
) {
  final handle = SessionStartingHandle._(
    ref,
    ref.watch(localProfileGenerationProvider),
    ref.watch(sessionRepositoryProvider),
    templateId,
  );
  ref.onDispose(handle.dispose);
  return handle;
});
