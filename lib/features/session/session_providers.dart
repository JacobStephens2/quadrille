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
final sessionGridProvider =
    StreamProvider.family<List<SessionGridRow>, String>((ref, id) {
      return ref.watch(sessionRepositoryProvider).watchGrid(id);
    });

/// Owns set logging and retains the exact last action even when persisted
/// completion timestamps tie. Widgets only forward the entry fields.
class SessionSetController extends Notifier<SetEntry?> {
  SessionSetController(this.sessionId);

  final String sessionId;

  @override
  SetEntry? build() => null;

  Future<void> saveSet({
    required SessionExercise exercise,
    required SetEntry set,
    required SetStatus status,
    double? weight,
    int? reps,
    int? leftReps,
    int? rightReps,
    double? rpe,
    int? partials,
    String? notes,
  }) async {
    final repo = ref.read(sessionRepositoryProvider);
    final autoStart = ref.read(settingsProvider).value?.autoStartTimer ?? true;
    final timer = ref.read(restTimerControllerProvider);
    await repo.saveSet(
      set.id,
      weight: weight,
      reps: reps,
      leftReps: leftReps,
      rightReps: rightReps,
      rpe: rpe,
      partials: partials,
      notes: notes,
      status: status,
    );
    if (!ref.mounted) return;
    state = set;
    if (status != SetStatus.completed || !autoStart) return;
    final next = nextPendingSessionSet(
      await repo.readGrid(sessionId),
      after: set,
    );
    await timer.start(
      duration: Duration(seconds: exercise.plannedRestSeconds),
      sessionId: sessionId,
      sessionExerciseId: next?.exercise.id,
      label:
          next?.label ??
          (exercise.supersetGroup == null
              ? 'Exercise complete'
              : 'Superset block complete'),
    );
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
