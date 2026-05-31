import 'package:drift/drift.dart';

import '../database/database.dart';
import '../domain/enums.dart';
import '../domain/ids.dart';

/// A generic starter set of common movements, seeded once on first launch so
/// the catalog isn't empty. These are deliberately generic — a user's actual
/// templates are built (or imported) from their own sheets, not assumed here.
const _starter = <(String, ExerciseCategory, int, LoadKind)>[
  // Push
  ('Barbell Bench Press', ExerciseCategory.push, 180, LoadKind.externalWeight),
  ('Overhead Press', ExerciseCategory.shoulders, 150, LoadKind.externalWeight),
  ('Incline Dumbbell Press', ExerciseCategory.push, 150, LoadKind.externalWeight),
  ('Cable Fly', ExerciseCategory.push, 90, LoadKind.externalWeight),
  ('Lateral Raise', ExerciseCategory.shoulders, 90, LoadKind.externalWeight),
  ('Triceps Pushdown', ExerciseCategory.arms, 90, LoadKind.externalWeight),
  ('Overhead Triceps Extension', ExerciseCategory.arms, 90, LoadKind.externalWeight),
  // Pull
  ('Barbell Row', ExerciseCategory.pull, 150, LoadKind.externalWeight),
  ('Chest-Supported Row', ExerciseCategory.pull, 120, LoadKind.externalWeight),
  ('Lat Pulldown', ExerciseCategory.pull, 120, LoadKind.externalWeight),
  ('Pull-Up', ExerciseCategory.pull, 150, LoadKind.bodyweight),
  ('Seated Cable Row', ExerciseCategory.pull, 120, LoadKind.externalWeight),
  ('Face Pull', ExerciseCategory.pull, 90, LoadKind.externalWeight),
  ('Straight-Arm Pulldown', ExerciseCategory.pull, 90, LoadKind.externalWeight),
  ('Barbell Curl', ExerciseCategory.arms, 90, LoadKind.externalWeight),
  ('Hammer Curl', ExerciseCategory.arms, 90, LoadKind.externalWeight),
  // Legs
  ('Back Squat', ExerciseCategory.legs, 210, LoadKind.externalWeight),
  ('Romanian Deadlift', ExerciseCategory.legs, 180, LoadKind.externalWeight),
  ('Leg Press', ExerciseCategory.legs, 150, LoadKind.externalWeight),
  ('Leg Extension', ExerciseCategory.legs, 90, LoadKind.externalWeight),
  ('Seated Leg Curl', ExerciseCategory.legs, 90, LoadKind.externalWeight),
  ('Hip Thrust', ExerciseCategory.legs, 150, LoadKind.externalWeight),
  ('Standing Calf Raise', ExerciseCategory.legs, 75, LoadKind.externalWeight),
  // Core
  ('Hanging Leg Raise', ExerciseCategory.core, 90, LoadKind.bodyweight),
  ('Cable Crunch', ExerciseCategory.core, 90, LoadKind.externalWeight),
];

/// Inserts the starter catalog only when the exercises table is empty, so it
/// runs exactly once and never duplicates or overwrites user edits.
Future<void> seedStarterDataIfEmpty(QuadrilleDatabase db) async {
  final existing = await (db.select(db.exercises)..limit(1)).get();
  if (existing.isNotEmpty) return;

  final now = DateTime.now();
  await db.batch((batch) {
    for (final (name, category, restSeconds, loadKind) in _starter) {
      batch.insert(
        db.exercises,
        ExercisesCompanion.insert(
          id: newId(),
          name: name,
          category: Value(category),
          defaultRestSeconds: Value(restSeconds),
          loadKind: Value(loadKind),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  });
}
