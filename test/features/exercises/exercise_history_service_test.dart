import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/features/exercises/data/exercise_history_service.dart';
import 'package:quadrille/features/exercises/domain/exercise_history.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  late QuadrilleDatabase db;
  late TemplateRepository templates;
  late SessionRepository sessions;
  late ExerciseHistoryService history;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    templates = TemplateRepository(db);
    sessions = SessionRepository(db);
    history = ExerciseHistoryService(db);
  });
  tearDown(() => db.close());

  /// Runs a session of "Bench Press" logging [weights] x [reps], completing it.
  Future<void> logSession(List<(double, int)> sets, {bool complete = true}) async {
    final tId = await templates.createTemplate(name: 'Push');
    await templates.addExercise(
      tId,
      TemplateExerciseDraft(
        displayName: 'Bench Press',
        orderLabel: '1',
        targetSets: sets.length,
        repTarget: RepTarget.reps(5, 8),
      ),
    );
    final sId = await sessions.startFromTemplate(tId);
    final setRows = await sessions.watchSets(sId).first;
    for (var i = 0; i < sets.length; i++) {
      await sessions.saveSet(setRows[i].id, weight: sets[i].$1, reps: sets[i].$2);
    }
    if (complete) await sessions.completeSession(sId);
  }

  test('groups completed sessions newest-first and computes PRs', () async {
    await logSession([(135, 8), (135, 6)]);
    await logSession([(145, 5), (140, 5)]);

    final h = await history.forName('Bench Press');
    expect(h.sessions, hasLength(2));
    // Heaviest weight across all sessions.
    expect(h.stats.heaviestWeight, 145);
    // Best est 1RM: 145*(1+5/30)=169.17 vs 135*(1+8/30)=171 -> 135x8 wins.
    expect(h.stats.bestSet?.weight, 135);
    expect(h.stats.bestSet?.reps, 8);
    expect(h.stats.sessionCount, 2);
  });

  test('matches case-insensitively', () async {
    await logSession([(100, 5)]);
    final h = await history.forName('bench PRESS');
    expect(h.sessions, hasLength(1));
  });

  test('excludes in-progress (non-completed) sessions', () async {
    await logSession([(100, 5)], complete: false);
    final h = await history.forName('Bench Press');
    expect(h.sessions, isEmpty);
    expect(h.stats.isEmpty, isTrue);
  });

  test('estimatedOneRepMax uses Epley and ignores incomplete data', () {
    final base = SetEntry(
      id: 'x',
      sessionExerciseId: 's',
      setNumber: 1,
      weightUnit: WeightUnit.lb,
      status: SetStatus.completed,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    expect(estimatedOneRepMax(base.copyWith(weight: const Value(100), reps: const Value(10))),
        closeTo(133.3, 0.1));
    expect(estimatedOneRepMax(base), isNull);
  });
}
