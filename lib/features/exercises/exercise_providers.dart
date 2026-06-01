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
final exerciseByIdProvider =
    FutureProvider.family<Exercise?, String>((ref, id) {
  return ref.watch(exerciseRepositoryProvider).getById(id);
});

final exerciseHistoryServiceProvider = Provider<ExerciseHistoryService>((ref) {
  return ExerciseHistoryService(ref.watch(databaseProvider));
});

/// History + PRs for an exercise, matched by display name. Re-reads when the
/// underlying session data changes via [_historyRevisionProvider].
final exerciseHistoryProvider =
    FutureProvider.family<ExerciseHistory, String>((ref, displayName) {
  ref.watch(_historyRevisionProvider);
  return ref.watch(exerciseHistoryServiceProvider).forName(displayName);
});

/// Bumps whenever set entries change, so open history views refresh.
final _historyRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.setEntries).watch().map((rows) => rows.length);
});
