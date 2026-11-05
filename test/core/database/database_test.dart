import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/ids.dart';

void main() {
  late QuadrilleDatabase db;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('seeds a singleton settings row on first open', () async {
    final settings = await db.select(db.appSettingsTable).getSingle();
    expect(settings.id, 'singleton');
    expect(settings.units, WeightUnit.lb);
    expect(settings.autoStartTimer, isTrue);
  });

  test('upgrades v5 logged sets to v6 without losing their data', () async {
    await db.close();
    db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite) {
          // Frozen v5 fixture: this must not derive from the current schema.
          sqlite.execute('''
            CREATE TABLE set_entries (
              id TEXT NOT NULL PRIMARY KEY,
              session_exercise_id TEXT NOT NULL,
              set_number INTEGER NOT NULL,
              weight REAL,
              weight_unit TEXT NOT NULL DEFAULT 'lb',
              reps INTEGER,
              left_reps INTEGER,
              right_reps INTEGER,
              status TEXT NOT NULL DEFAULT 'pending',
              rpe REAL,
              pain TEXT,
              notes TEXT,
              started_at INTEGER,
              completed_at INTEGER,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              deleted_at INTEGER
            );
            INSERT INTO set_entries (
              id, session_exercise_id, set_number, weight, reps, status,
              rpe, notes, completed_at, created_at, updated_at
            ) VALUES (
              'old-set', 'curl', 1, 30, 15, 'completed',
              9, 'Controlled tempo', 100, 100, 100
            );
            PRAGMA user_version = 5;
          ''');
        },
      ),
    );
    final upgraded = db;

    final set = await upgraded.select(upgraded.setEntries).getSingle();
    expect(set.id, 'old-set');
    expect(set.weight, 30);
    expect(set.reps, 15);
    expect(set.rpe, 9);
    expect(set.notes, 'Controlled tempo');
    expect(set.status, SetStatus.completed);
    expect(set.completedAt, isNotNull);
    expect(set.partials, isNull);
    expect(
      (await upgraded.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      6,
    );

    await upgraded
        .update(upgraded.setEntries)
        .write(const SetEntriesCompanion(partials: Value(4)));
    expect(
      (await upgraded.select(upgraded.setEntries).getSingle()).partials,
      4,
    );
  });

  test('round-trips a template with an enum-stored load kind', () async {
    final now = DateTime.now();
    final id = newId();
    await db.into(db.workoutTemplates).insert(
          WorkoutTemplatesCompanion.insert(
            id: id,
            name: 'Day 1 Push A',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.templateExercises).insert(
          TemplateExercisesCompanion.insert(
            id: newId(),
            templateId: id,
            displayName: 'Overhead Press',
            orderLabel: '1',
            sortIndex: 100,
            loadKind: const Value(LoadKind.externalWeight),
            createdAt: now,
            updatedAt: now,
          ),
        );

    final rows = await db.select(db.templateExercises).get();
    expect(rows, hasLength(1));
    expect(rows.single.displayName, 'Overhead Press');
    expect(rows.single.loadKind, LoadKind.externalWeight);
  });

  test('enforces foreign keys (cascade delete)', () async {
    final now = DateTime.now();
    final templateId = newId();
    await db.into(db.workoutTemplates).insert(
          WorkoutTemplatesCompanion.insert(
            id: templateId,
            name: 'Throwaway',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.templateExercises).insert(
          TemplateExercisesCompanion.insert(
            id: newId(),
            templateId: templateId,
            displayName: 'Squat',
            orderLabel: '1',
            sortIndex: 100,
            createdAt: now,
            updatedAt: now,
          ),
        );

    await (db.delete(db.workoutTemplates)
          ..where((t) => t.id.equals(templateId)))
        .go();

    final remaining = await db.select(db.templateExercises).get();
    expect(remaining, isEmpty, reason: 'cascade should remove child rows');
  });
}
