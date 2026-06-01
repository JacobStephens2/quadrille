import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  late QuadrilleDatabase db;
  late TemplateRepository repo;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    repo = TemplateRepository(db);
  });
  tearDown(() => db.close());

  test('creates a template and lists it', () async {
    await repo.createTemplate(name: 'Day 1 Push A', dayLabel: 'Push A');
    final templates = await repo.watchTemplates().first;
    expect(templates, hasLength(1));
    expect(templates.single.name, 'Day 1 Push A');
  });

  test('exercise rows come back in sheet order (1, 2A, 2B, 3)', () async {
    final id = await repo.createTemplate(name: 'T');
    // Add out of order to prove sorting is by parsed order, not insertion.
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Row', orderLabel: '2B'));
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Press', orderLabel: '1'));
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Fly', orderLabel: '2A'));
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Curl', orderLabel: '3'));

    final rows = await repo.watchExercises(id).first;
    expect(rows.map((r) => r.orderLabel).toList(), ['1', '2A', '2B', '3']);
  });

  test('superset members get a shared group key', () async {
    final id = await repo.createTemplate(name: 'T');
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Press', orderLabel: '1'));
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Fly', orderLabel: '2A'));
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Row', orderLabel: '2B'));

    final rows = await repo.watchExercises(id).first;
    expect(rows[0].supersetGroup, isNull);
    expect(rows[1].supersetGroup, '2');
    expect(rows[2].supersetGroup, '2');
  });

  test('persists rep target columns from RepTarget', () async {
    final id = await repo.createTemplate(name: 'T');
    await repo.addExercise(
      id,
      TemplateExerciseDraft(
        displayName: 'Bench',
        orderLabel: '1',
        repTarget: RepTarget.reps(6, 8),
        restSeconds: 180,
      ),
    );
    final row = (await repo.watchExercises(id).first).single;
    expect(row.repMin, 6);
    expect(row.repMax, 8);
    expect(row.restSeconds, 180);
  });

  test('duplicate copies all rows under a new template', () async {
    final id = await repo.createTemplate(name: 'Push A');
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Bench', orderLabel: '1'));
    await repo.addExercise(id, TemplateExerciseDraft(displayName: 'Press', orderLabel: '2'));

    final copyId = await repo.duplicateTemplate(id, newName: 'Push A (copy)');
    expect(copyId, isNot(id));

    final originalRows = await repo.watchExercises(id).first;
    final copyRows = await repo.watchExercises(copyId).first;
    expect(copyRows.map((r) => r.displayName), originalRows.map((r) => r.displayName));
    // New rows have new ids.
    expect(
      copyRows.map((r) => r.id).toSet().intersection(
            originalRows.map((r) => r.id).toSet(),
          ),
      isEmpty,
    );
  });

  test('persists a linked catalog exerciseId from the draft', () async {
    final exerciseId = await ExerciseRepository(db).create(name: 'Back Squat');
    final id = await repo.createTemplate(name: 'T');
    await repo.addExercise(
      id,
      TemplateExerciseDraft(
        displayName: 'Back Squat',
        orderLabel: '1',
        exerciseId: exerciseId,
      ),
    );
    final row = (await repo.watchExercises(id).first).single;
    expect(row.exerciseId, exerciseId);
  });

  test('archived templates are excluded from the list', () async {
    final id = await repo.createTemplate(name: 'Old');
    await repo.archiveTemplate(id);
    expect(await repo.watchTemplates().first, isEmpty);
  });

  test('delete removes a single exercise row', () async {
    final id = await repo.createTemplate(name: 'T');
    final rowId = await repo.addExercise(
      id,
      TemplateExerciseDraft(displayName: 'Bench', orderLabel: '1'),
    );
    await repo.deleteExercise(rowId);
    expect(await repo.watchExercises(id).first, isEmpty);
  });
}
