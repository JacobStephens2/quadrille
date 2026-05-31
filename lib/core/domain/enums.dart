/// Shared enumerations used across the domain and persisted by Drift.
///
/// These are stored in SQLite by their [name] (a stable string) rather than
/// their index, so reordering or inserting values never corrupts existing
/// rows. The database layer maps them with a `TextColumn` + converter.
library;

/// The unit a load is expressed in. Stored per set so a session can mix units.
enum WeightUnit {
  lb,
  kg;

  String get label => switch (this) {
        WeightUnit.lb => 'lb',
        WeightUnit.kg => 'kg',
      };
}

/// How an exercise's load is tracked. Not every movement uses external weight,
/// so set entry never assumes a numeric barbell load.
enum LoadKind {
  /// Plated/dumbbell/machine load entered as a number (the common case).
  externalWeight,

  /// Pure bodyweight (the sheet's "b").
  bodyweight,

  /// Bodyweight minus assistance (e.g. assisted pull-ups).
  assistedBodyweight,

  /// A machine pin/setting number rather than a true weight.
  machineSetting,

  /// Timed hold/carry — duration matters, not weight.
  timeOnly,

  /// No load tracked.
  none,
}

/// Lifecycle of a single workout session.
enum SessionStatus {
  /// Created but not yet started (rare; sessions usually start immediately).
  planned,

  /// Currently being logged on the gym floor.
  active,

  /// Finished.
  completed,

  /// Abandoned without completing.
  abandoned,
}

/// Outcome of a single logged set.
enum SetStatus {
  /// Not yet performed — an empty cell in the grid.
  pending,

  /// Performed as planned.
  completed,

  /// Intentionally skipped.
  skipped,

  /// A warm-up set (excluded from working-set analytics later).
  warmup,

  /// Attempted but failed to complete target reps.
  failed,

  /// Equipment unavailable / had to wait (the sheet's "wait").
  unavailable,
}

/// Coarse pain flag mirroring the sheet's "P = pain" annotation.
enum PainLevel {
  none,
  mild,
  moderate,
  severe;

  String get label => switch (this) {
        PainLevel.none => 'None',
        PainLevel.mild => 'Mild',
        PainLevel.moderate => 'Moderate',
        PainLevel.severe => 'Severe',
      };
}

/// Broad movement category for the exercise catalog.
enum ExerciseCategory {
  push,
  pull,
  legs,
  core,
  arms,
  shoulders,
  cardio,
  other;

  String get label => switch (this) {
        ExerciseCategory.push => 'Push',
        ExerciseCategory.pull => 'Pull',
        ExerciseCategory.legs => 'Legs',
        ExerciseCategory.core => 'Core',
        ExerciseCategory.arms => 'Arms',
        ExerciseCategory.shoulders => 'Shoulders',
        ExerciseCategory.cardio => 'Cardio',
        ExerciseCategory.other => 'Other',
      };
}
