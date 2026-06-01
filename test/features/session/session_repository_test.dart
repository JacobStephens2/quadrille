import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  late QuadrilleDatabase db;
  late TemplateRepository templates;
  late SessionRepository sessions;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    templates = TemplateRepository(db);
    sessions = SessionRepository(db);
  });
  tearDown(() => db.close());

  Future<String> seedTemplate() async {
    final id = await templates.createTemplate(name: 'Push A');
    await templates.addExercise(
      id,
      TemplateExerciseDraft(
        displayName: 'Bench Press',
        orderLabel: '1',
        targetSets: 3,
        repTarget: RepTarget.reps(6, 8),
        restSeconds: 180,
      ),
    );
    await templates.addExercise(
      id,
      TemplateExerciseDraft(
        displayName: 'Overhead Press',
        orderLabel: '2',
        targetSets: 2,
        repTarget: RepTarget.reps(8, 10),
      ),
    );
    return id;
  }

  test('startFromTemplate clones rows and pre-creates empty sets', () async {
    final templateId = await seedTemplate();
    final sessionId = await sessions.startFromTemplate(templateId);

    final session = await sessions.watchSession(sessionId).first;
    expect(session!.name, 'Push A');
    expect(session.status, SessionStatus.active);

    final grid = buildGrid(
      await sessions.watchExercises(sessionId).first,
      await sessions.watchSets(sessionId).first,
    );
    expect(grid.map((r) => r.exercise.displayName), ['Bench Press', 'Overhead Press']);
    // 3 + 2 placeholder sets, all pending.
    expect(grid[0].sets, hasLength(3));
    expect(grid[1].sets, hasLength(2));
    expect(grid.expand((r) => r.sets).every((s) => s.status == SetStatus.pending), isTrue);
    expect(grid[0].sets.map((s) => s.setNumber), [1, 2, 3]);
  });

  test('editing the template after start does NOT mutate the session', () async {
    final templateId = await seedTemplate();
    final rows = await templates.watchExercises(templateId).first;
    final sessionId = await sessions.startFromTemplate(templateId);

    // Mutate the template row after the session started.
    await templates.updateExercise(
      rows.first.id,
      templateId,
      TemplateExerciseDraft(
        displayName: 'Incline Bench (changed)',
        orderLabel: '1',
        targetSets: 99,
      ),
    );

    final sessionEx = await sessions.watchExercises(sessionId).first;
    expect(sessionEx.first.displayName, 'Bench Press');
    expect(sessionEx.first.plannedSets, 3);
  });

  test('saveSet records weight/reps, marks completed, stamps completedAt', () async {
    final templateId = await seedTemplate();
    final sessionId = await sessions.startFromTemplate(templateId);
    final firstSet = (await sessions.watchSets(sessionId).first).first;

    await sessions.saveSet(firstSet.id, weight: 135, reps: 8);

    final updated = (await sessions.watchSets(sessionId).first)
        .firstWhere((s) => s.id == firstSet.id);
    expect(updated.weight, 135);
    expect(updated.reps, 8);
    expect(updated.status, SetStatus.completed);
    expect(updated.completedAt, isNotNull);
  });

  test('addSet appends with the next set number', () async {
    final templateId = await seedTemplate();
    final sessionId = await sessions.startFromTemplate(templateId);
    final benchEx = (await sessions.watchExercises(sessionId).first).first;

    await sessions.addSet(benchEx.id);

    final grid = buildGrid(
      await sessions.watchExercises(sessionId).first,
      await sessions.watchSets(sessionId).first,
    );
    expect(grid.first.sets, hasLength(4));
    expect(grid.first.sets.last.setNumber, 4);
  });

  test('completeSession moves it out of active and into history', () async {
    final templateId = await seedTemplate();
    final sessionId = await sessions.startFromTemplate(templateId);
    expect(await sessions.watchActiveSession().first, isNotNull);

    await sessions.completeSession(sessionId);

    expect(await sessions.watchActiveSession().first, isNull);
    final history = await sessions.watchHistory().first;
    expect(history, hasLength(1));
    expect(history.single.completedAt, isNotNull);
  });

  test('grid row progress reflects completed sets', () async {
    final templateId = await seedTemplate();
    final sessionId = await sessions.startFromTemplate(templateId);
    final sets = await sessions.watchSets(sessionId).first;
    await sessions.saveSet(sets.first.id, weight: 100, reps: 8);

    final grid = buildGrid(
      await sessions.watchExercises(sessionId).first,
      await sessions.watchSets(sessionId).first,
    );
    expect(grid.first.completedCount, 1);
    expect(grid.first.totalCount, 3);
    expect(grid.first.isDone, isFalse);
  });
}
