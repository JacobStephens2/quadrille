import 'package:drift/drift.dart';
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
