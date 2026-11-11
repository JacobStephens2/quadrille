import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../auth/auth_controller.dart';
import '../sync/sync_coordinator.dart';
import '../timer/timer_providers.dart';
import 'data/session_repository.dart';
import 'session_providers.dart';

enum SessionEndingIntent { finish, discard }

enum SessionEndingStatus { ended, superseded, unavailable, failed }

class SessionEndingOutcome {
  const SessionEndingOutcome.ended(this.intent)
    : status = SessionEndingStatus.ended,
      error = null;
  const SessionEndingOutcome.superseded()
    : status = SessionEndingStatus.superseded,
      intent = null,
      error = null;
  const SessionEndingOutcome.unavailable()
    : status = SessionEndingStatus.unavailable,
      intent = null,
      error = null;
  const SessionEndingOutcome.failed(this.error)
    : status = SessionEndingStatus.failed,
      intent = null;

  final SessionEndingStatus status;
  final SessionEndingIntent? intent;
  final Object? error;
}

/// Captured collaborators outlive screen removal; ownership is shared in core.
class _SessionEndingOwner {
  _SessionEndingOwner(this.ref, this.generation)
    : repository = ref.read(sessionRepositoryProvider),
      timer = ref.read(restTimerControllerProvider);

  final Ref ref;
  final LocalProfileGeneration generation;
  final SessionRepository repository;
  final RestTimerController timer;

  bool get isCurrent => ref.mounted && generation.isCurrent;
}

final _sessionEndingOwnerProvider = Provider<_SessionEndingOwner>((ref) {
  return _SessionEndingOwner(ref, ref.watch(localProfileGenerationProvider));
});

/// Bind before opening confirmation and retain this exact handle for its answer.
/// Duplicate/conflicting accepted intents share work; the first intent wins.
/// Local success is terminal, errors permit retry, and upload is best effort.
class SessionEndingHandle extends ChangeNotifier {
  SessionEndingHandle._(this._owner, this.sessionId);

  final _SessionEndingOwner _owner;
  final String sessionId;
  Future<SessionEndingOutcome>? _pending;
  SessionEndingOutcome? _outcome;
  bool _disposed = false;

  bool get isCurrent => !_disposed && _owner.isCurrent;
  bool get isPending => _pending != null;
  SessionEndingOutcome? get outcome => _outcome;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<SessionEndingOutcome> end(SessionEndingIntent intent) {
    if (_pending case final pending?) return pending;
    if (!isCurrent) {
      return Future.value(const SessionEndingOutcome.superseded());
    }
    final previous = _outcome;
    if (previous != null && previous.status == SessionEndingStatus.ended) {
      return Future.value(previous);
    }

    // Publish before any async stage or collaborator can re-enter this handle.
    final completion = Completer<SessionEndingOutcome>();
    _pending = completion.future;
    _outcome = null;
    notifyListeners();
    unawaited(() async {
      final result = await _run(intent);
      final outcome = isCurrent
          ? result
          : const SessionEndingOutcome.superseded();
      _outcome = outcome;
      _pending = null;
      if (!_disposed) notifyListeners();
      completion.complete(outcome);
    }());
    return completion.future;
  }

  Future<SessionEndingOutcome> _run(SessionEndingIntent intent) async {
    try {
      if (!isCurrent) return const SessionEndingOutcome.superseded();
      final ref = _owner.ref;
      // Sync credentials belong to acceptance time, independently of the local
      // generation. Account sync retains verification and Auto-sync policy.
      final syncContext = intent == SessionEndingIntent.finish
          ? ref.read(authSyncContextProvider)
          : null;
      final sync = syncContext == null
          ? null
          : ref.read(syncCoordinatorProvider);
      if (!isCurrent) return const SessionEndingOutcome.superseded();
      final active = await _owner.repository.isActiveSession(sessionId);
      if (!isCurrent) return const SessionEndingOutcome.superseded();
      if (!active) return const SessionEndingOutcome.unavailable();

      await _owner.timer.skip();
      if (!isCurrent) return const SessionEndingOutcome.superseded();
      final changed = switch (intent) {
        SessionEndingIntent.finish => await _owner.repository.completeSession(
          sessionId,
        ),
        SessionEndingIntent.discard => await _owner.repository.discardSession(
          sessionId,
        ),
      };
      if (!isCurrent) return const SessionEndingOutcome.superseded();
      if (!changed) return const SessionEndingOutcome.unavailable();

      if (sync != null &&
          syncContext!.profileName == _owner.generation.profileName &&
          identical(
            ref.read(authSyncContextProvider)?.generation,
            syncContext.generation,
          ) &&
          isCurrent) {
        unawaited(
          Future<void>.sync(sync.pushAfterFinish).catchError((Object _) {}),
        );
      }
      return SessionEndingOutcome.ended(intent);
    } catch (error) {
      return isCurrent
          ? SessionEndingOutcome.failed(error)
          : const SessionEndingOutcome.superseded();
    }
  }
}

final sessionEndingProvider = Provider.family<SessionEndingHandle, String>((
  ref,
  sessionId,
) {
  final handle = SessionEndingHandle._(
    ref.watch(_sessionEndingOwnerProvider),
    sessionId,
  );
  ref.onDispose(handle.dispose);
  return handle;
});
