import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import 'data/session_repository.dart';
import 'domain/session_grid.dart';

final sessionRepositoryProvider = Provider<SessionRepository>((ref) {
  return SessionRepository(ref.watch(databaseProvider));
});

/// The current active session (or null) — drives Today's resume/start state.
final activeSessionProvider = StreamProvider<WorkoutSession?>((ref) {
  return ref.watch(sessionRepositoryProvider).watchActiveSession();
});

final sessionProvider =
    StreamProvider.family<WorkoutSession?, String>((ref, id) {
  return ref.watch(sessionRepositoryProvider).watchSession(id);
});

/// Completed sessions for the History tab.
final historyProvider = StreamProvider<List<WorkoutSession>>((ref) {
  return ref.watch(sessionRepositoryProvider).watchHistory();
});

final _sessionExercisesProvider =
    StreamProvider.family<List<SessionExercise>, String>((ref, id) {
  return ref.watch(sessionRepositoryProvider).watchExercises(id);
});

final _sessionSetsProvider =
    StreamProvider.family<List<SetEntry>, String>((ref, id) {
  return ref.watch(sessionRepositoryProvider).watchSets(id);
});

/// The composed grid (exercise rows + their sets) for a session. Combines the
/// exercises and sets streams; emits only when both have data.
final sessionGridProvider =
    Provider.family<AsyncValue<List<SessionGridRow>>, String>((ref, id) {
  final exercises = ref.watch(_sessionExercisesProvider(id));
  final sets = ref.watch(_sessionSetsProvider(id));
  return exercises.when(
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
    data: (ex) => sets.when(
      loading: () => const AsyncValue.loading(),
      error: AsyncValue.error,
      data: (st) => AsyncValue.data(buildGrid(ex, st)),
    ),
  );
});
