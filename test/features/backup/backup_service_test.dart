import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  Future<String> seedAndExport() async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final templates = TemplateRepository(db);
    final sessions = SessionRepository(db);
    await ExerciseRepository(db).create(name: 'Bench Press');
    final tId = await templates.createTemplate(name: 'Push A');
    await templates.addExercise(
      tId,
      TemplateExerciseDraft(
        displayName: 'Bench Press',
        orderLabel: '1',
        repTarget: RepTarget.reps(6, 8),
      ),
    );
    final sId = await sessions.startFromTemplate(tId);
    final firstSet = (await sessions.watchSets(sId).first).first;
    await sessions.saveSet(firstSet.id, weight: 135, reps: 8);
    final json = await BackupService(db).exportJson(now: DateTime(2026, 6, 1));
    await db.close();
    return json;
  }

  test('round-trips all data through export then import', () async {
    final json = await seedAndExport();

    final fresh = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    final summary = await BackupService(fresh).importJson(json);

    expect(summary.exercises, 1);
    expect(summary.templates, 1);
    expect(summary.sessions, 1);
    // 3 placeholder set rows were pre-created from the template (1 logged).
    expect(summary.sets, 3);

    final exercises = await ExerciseRepository(fresh).watchAll().first;
    expect(exercises.single.name, 'Bench Press');

    final restoredSets =
        await SessionRepository(fresh).watchSets(
      (await fresh.select(fresh.workoutSessions).getSingle()).id,
    ).first;
    final logged = restoredSets.firstWhere((s) => s.weight != null);
    expect(logged.weight, 135);
    expect(logged.reps, 8);
  });

  test('import replaces existing data', () async {
    final json = await seedAndExport();
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // Pre-existing junk that should be wiped by the restore.
    await ExerciseRepository(db).create(name: 'Stale Exercise');

    await BackupService(db).importJson(json);
    final names = (await ExerciseRepository(db).watchAll().first)
        .map((e) => e.name)
        .toList();
    expect(names, ['Bench Press']);
  });

  test('rejects non-JSON', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      () => BackupService(db).importJson('not json {'),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('rejects a foreign JSON file', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      () => BackupService(db).importJson('{"format":"something else"}'),
      throwsA(isA<BackupFormatException>()),
    );
  });

  group('mergeIntoLocal (row-level LWW)', () {
    test('newer incoming wins; older incoming is ignored', () async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = ExerciseRepository(db);
      final backup = BackupService(db);
      final id = await repo.create(name: 'Original');
      final base = (await repo.getById(id))!.toJson();

      // Newer update applies.
      await backup.mergeIntoLocal({
        'tables': {
          'exercises': [
            {...base, 'name': 'Updated', 'updatedAt': (base['updatedAt'] as int) + 1000},
          ],
        },
      });
      expect((await repo.getById(id))!.name, 'Updated');

      // Older update is ignored.
      await backup.mergeIntoLocal({
        'tables': {
          'exercises': [
            {...base, 'name': 'Stale', 'updatedAt': (base['updatedAt'] as int) - 1000},
          ],
        },
      });
      expect((await repo.getById(id))!.name, 'Updated');
    });

    test('a tombstone from cloud hides a template row locally', () async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final templates = TemplateRepository(db);
      final backup = BackupService(db);
      final tId = await templates.createTemplate(name: 'T');
      await templates.addExercise(
        tId,
        TemplateExerciseDraft(displayName: 'Bench', orderLabel: '1'),
      );
      final row = (await templates.watchExercises(tId).first).single;
      final json = row.toJson();

      await backup.mergeIntoLocal({
        'tables': {
          'templateExercises': [
            {...json, 'deletedAt': (json['updatedAt'] as int) + 1000},
          ],
        },
      });
      expect(await templates.watchExercises(tId).first, isEmpty);
    });
  });
}
