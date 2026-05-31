import 'package:drift/drift.dart';

import '../domain/enums.dart';
import 'connection/connection.dart';
import 'tables.dart';

part 'database.g.dart';

/// The Quadrille local-first SQLite database (Drift).
///
/// This is the single source of truth across all platforms. Repositories sit
/// on top of it; the UI never touches SQL directly, which is the seam that
/// later lets cloud sync slot in without touching a widget.
@DriftDatabase(
  tables: [
    Exercises,
    WorkoutTemplates,
    TemplateExercises,
    WorkoutSessions,
    SessionExercises,
    SetEntries,
    AppSettingsTable,
  ],
)
class QuadrilleDatabase extends _$QuadrilleDatabase {
  QuadrilleDatabase() : super(openConnection());

  /// In-memory / custom executor constructor for tests.
  QuadrilleDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        beforeOpen: (details) async {
          // Foreign keys are off by default in SQLite; enable per-connection.
          await customStatement('PRAGMA foreign_keys = ON');
          if (details.wasCreated) {
            // Seed the singleton settings row on first launch.
            await into(appSettingsTable).insert(
              AppSettingsTableCompanion.insert(units: const Value(WeightUnit.lb)),
            );
          }
        },
      );
}
