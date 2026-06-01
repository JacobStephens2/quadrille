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
    ActiveTimers,
  ],
)
class QuadrilleDatabase extends _$QuadrilleDatabase {
  QuadrilleDatabase() : super(openConnection());

  /// In-memory / custom executor constructor for tests.
  QuadrilleDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v2 introduces the active_timers table.
          if (from < 2) {
            await m.createTable(activeTimers);
          }
          // v3 adds cloud-sync settings columns.
          if (from < 3) {
            await m.addColumn(appSettingsTable, appSettingsTable.syncEndpoint);
            await m.addColumn(appSettingsTable, appSettingsTable.syncToken);
          }
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
