import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import 'data/exercise_history_service.dart';
import 'data/exercise_repository.dart';
import 'domain/exercise_history.dart';

final exerciseRepositoryProvider = Provider<ExerciseRepository>((ref) {
  return ExerciseRepository(ref.watch(databaseProvider));
});

/// Reactive list of non-archived exercises for the catalog UI.
final exercisesProvider = StreamProvider<List<Exercise>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchAll();
});

/// A single catalog exercise by id (for its detail screen).
final exerciseByIdProvider = FutureProvider.family<Exercise?, String>((
  ref,
  id,
) {
  return ref.watch(exerciseRepositoryProvider).getById(id);
});

final exerciseHistoryServiceProvider = Provider<ExerciseHistoryService>((ref) {
  return ExerciseHistoryService(ref.watch(databaseProvider));
});

/// Complete live history + PRs for an exercise, matched by display name.
final exerciseHistoryProvider = StreamProvider.family<ExerciseHistory, String>((
  ref,
  displayName,
) {
  return ref.watch(exerciseHistoryServiceProvider).watchForName(displayName);
});
