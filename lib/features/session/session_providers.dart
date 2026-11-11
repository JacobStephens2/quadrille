import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/domain/enums.dart';
import '../../core/providers.dart';
import '../settings/settings_providers.dart';
import '../timer/timer_providers.dart';
import 'data/session_repository.dart';
import 'domain/session_grid.dart';

final sessionRepositoryProvider = Provider<SessionRepository>((ref) {
  return SessionRepository(ref.watch(databaseProvider));
});

/// The current active session (or null) — drives Today's resume/start state.
final activeSessionProvider = StreamProvider<WorkoutSession?>((ref) {
  return ref.watch(sessionRepositoryProvider).watchActiveSession();
});

final sessionProvider = StreamProvider.family<WorkoutSession?, String>((
  ref,
  id,
) {
  return ref.watch(sessionRepositoryProvider).watchSession(id);
});

/// Completed sessions for the History tab.
final historyProvider = StreamProvider<List<WorkoutSession>>((ref) {
  return ref.watch(sessionRepositoryProvider).watchHistory();
});

/// Complete Session grids, including references on the first emission.
final sessionGridProvider = StreamProvider.family<List<SessionGridRow>, String>(
  (ref, id) {
    return ref.watch(sessionRepositoryProvider).watchGrid(id);
  },
);

/// Capture domain collaborators alongside their Local profile generation.
class _SetLoggingOwner {
  _SetLoggingOwner(this.ref, this.generation)
    : repository = ref.read(sessionRepositoryProvider),
      timer = ref.read(restTimerControllerProvider);

  final Ref ref;
  final LocalProfileGeneration generation;
  final SessionRepository repository;
  final RestTimerController timer;

  bool get isCurrent => ref.mounted && generation.isCurrent;
}

final _setLoggingOwnerProvider = Provider<_SetLoggingOwner>((ref) {
  return _SetLoggingOwner(ref, ref.watch(localProfileGenerationProvider));
});

enum SetLoggingResult { saved, superseded }

/// One opening's fixed target and Local profile. Presentation disposal does not
/// cancel accepted work; only ownership changes prevent later stages.
class SetLoggingHandle implements Listenable {
  SetLoggingHandle._(
    this._owner,
    this._sessionId,
    this._exercise,
    this._set,
    this._publish,
  );

  final _SetLoggingOwner _owner;
  final String _sessionId;
  final SessionExercise _exercise;
  final SetEntry _set;
  final void Function(SetEntry) _publish;

  bool get isCurrent => _owner.isCurrent;

  @override
  void addListener(VoidCallback listener) =>
      _owner.generation.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _owner.generation.removeListener(listener);

  Future<SetLoggingResult> save({
    required SetStatus status,
    double? weight,
    int? reps,
    int? leftReps,
    int? rightReps,
    double? rpe,
    int? partials,
    String? notes,
  }) async {
    try {
      if (!isCurrent) return SetLoggingResult.superseded;
      final autoStart =
          _owner.ref.read(settingsProvider).value?.autoStartTimer ?? true;
      if (!isCurrent) return SetLoggingResult.superseded;
      await _owner.repository.saveSet(
        _set.id,
        weight: weight,
        reps: reps,
        leftReps: leftReps,
        rightReps: rightReps,
        rpe: rpe,
        partials: partials,
        notes: notes,
        status: status,
      );
      if (!isCurrent) return SetLoggingResult.superseded;
      _publish(_set);
      if (!isCurrent) return SetLoggingResult.superseded;
      if (status == SetStatus.completed && autoStart) {
        final rows = await _owner.repository.readGrid(_sessionId);
        if (!isCurrent) return SetLoggingResult.superseded;
        final next = nextPendingSessionSet(rows, after: _set);
        if (!isCurrent) return SetLoggingResult.superseded;
        await _owner.timer.start(
          duration: Duration(seconds: _exercise.plannedRestSeconds),
          sessionId: _sessionId,
          sessionExerciseId: next?.exercise.id,
          label:
              next?.label ??
              (_exercise.supersetGroup == null
                  ? 'Exercise complete'
                  : 'Superset block complete'),
        );
      }
      if (!isCurrent) return SetLoggingResult.superseded;
      return SetLoggingResult.saved;
    } catch (_) {
      if (!isCurrent) return SetLoggingResult.superseded;
      rethrow;
    }
  }
}

/// Retains the exact last action when persisted completion timestamps tie.
/// Each ownership generation starts with no last-logged recommendation input.
class SessionSetController extends Notifier<SetEntry?> {
  SessionSetController(this.sessionId);

  final String sessionId;
  late _SetLoggingOwner _owner;

  @override
  SetEntry? build() {
    _owner = ref.watch(_setLoggingOwnerProvider);
    return null;
  }

  SetLoggingHandle bind({
    required SessionExercise exercise,
    required SetEntry set,
  }) {
    final owner = _owner;
    return SetLoggingHandle._(owner, sessionId, exercise, set, (logged) {
      if (owner.isCurrent) state = logged;
    });
  }
}

final sessionSetControllerProvider =
    NotifierProvider.family<SessionSetController, SetEntry?, String>(
      SessionSetController.new,
    );

final sessionRecommendationProvider =
    Provider.family<SessionSetRecommendation?, String>((ref, id) {
      final rows = ref.watch(sessionGridProvider(id)).value;
      final lastLogged = ref.watch(sessionSetControllerProvider(id));
      return rows == null
          ? null
          : nextPendingSessionSet(rows, after: lastLogged);
    });
