import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
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

import 'history_fixture.dart';

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

  HistoryObservation observe() {
    final observation = HistoryObservation(history.watchForName('Bench Press'));
    addTearDown(observation.close);
    return observation;
  }

  /// Runs a session of "Bench Press" logging [weights] x [reps], completing it.
  Future<void> logSession(
    List<(double, int)> sets, {
    bool complete = true,
  }) async {
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
    final setRows = (await sessions.readGrid(sId)).single.sets;
    for (var i = 0; i < sets.length; i++) {
      await sessions.saveSet(
        setRows[i].id,
        weight: sets[i].$1,
        reps: sets[i].$2,
      );
    }
    if (complete) await sessions.completeSession(sId);
  }

  test('groups completed sessions newest-first and computes PRs', () async {
    await logSession([(135, 8), (135, 6)]);
    await logSession([(145, 5), (140, 5)]);

    final h = await history.watchForName('Bench Press').first;
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
    final h = await history.watchForName('bench PRESS').first;
    expect(h.sessions, hasLength(1));
  });

  test('excludes in-progress (non-completed) sessions', () async {
    await logSession([(100, 5)], complete: false);
    final h = await history.watchForName('Bench Press').first;
    expect(h.sessions, isEmpty);
    expect(h.stats.isEmpty, isTrue);
  });

  test('history records use Epley estimates', () async {
    await logSession([(100, 10)]);
    final result = await history.watchForName('Bench Press').first;
    expect(result.stats.bestEstimatedOneRepMax, closeTo(133.333, 0.001));
    expect(
      result.sessions.single.bestEstimatedOneRepMax,
      closeTo(133.333, 0.001),
    );
  });

  test(
    'only live completed rows with completion timestamps contribute',
    () async {
      final fixture = HistoryFixture(db);
      await fixture.workout('eligible');
      // A completed workout needs no separate completedAt timestamp.
      for (final status in SessionStatus.values.where(
        (s) => s != SessionStatus.completed,
      )) {
        await fixture.workout(status.name, status: status);
      }
      await fixture.session('empty');
      await fixture.workout('deleted-session');
      await (db.update(
        db.workoutSessions,
      )..where((s) => s.id.equals('deleted-session'))).write(
        WorkoutSessionsCompanion(deletedAt: Value(HistoryFixture.date)),
      );
      await fixture.exercise(
        'deleted-exercise',
        'eligible',
        deletedAt: HistoryFixture.date,
      );
      await fixture.set(
        'deleted-exercise-set',
        'deleted-exercise',
        weight: 900,
      );
      await fixture.set(
        'deleted-set',
        'eligible-exercise',
        weight: 900,
        deletedAt: HistoryFixture.date,
      );
      for (final status in SetStatus.values.where(
        (s) => s != SetStatus.completed,
      )) {
        await fixture.set(
          status.name,
          'eligible-exercise',
          weight: 900,
          status: status,
        );
      }
      await fixture.set(
        'missing-timestamp',
        'eligible-exercise',
        weight: 900,
        timestamp: false,
      );
      await fixture.exercise('unrelated', 'eligible', name: 'Squat');
      await fixture.set('unrelated-set', 'unrelated', weight: 900);

      final result = await history.watchForName('Bench Press').first;

      expect(result.sessions.map((s) => s.sessionId), ['eligible']);
      expect(result.sessions.single.sets.map((s) => s.id), ['eligible-set']);
      expect(result.stats.sessionCount, 1);
      expect(result.stats.heaviestWeight, 100);
      expect(result.stats.bestSet?.id, 'eligible-set');
      expect(result.stats.bestEstimatedOneRepMax, closeTo(133.333, 0.001));
      expect(result.stats.lastPerformed, HistoryFixture.date);
    },
  );

  test('ordering and equal records are deterministic at every tie', () async {
    final fixture = HistoryFixture(db);
    // Reverse insertion makes every missing tie-break visible.
    await fixture.workout('z-session');
    await fixture.session('a-session');
    await fixture.session('older', startedAt: DateTime(2026, 1, 1));
    await fixture.exercise('z-exercise', 'a-session', sortIndex: 2);
    await fixture.exercise('b-exercise', 'a-session', sortIndex: 1);
    await fixture.exercise('a-exercise', 'a-session', sortIndex: 1);
    await fixture.set('z-set', 'a-exercise');
    await fixture.set('a-set', 'a-exercise');
    await fixture.set('b-set', 'b-exercise');
    await fixture.set('sort-last', 'z-exercise');
    await fixture.set('number-last', 'a-exercise', number: 2);
    await fixture.exercise('older-exercise', 'older');
    await fixture.set('older-set', 'older-exercise');

    for (var read = 0; read < 2; read++) {
      final result = await history.watchForName('Bench Press').first;
      expect(result.sessions.map((s) => s.sessionId), [
        'a-session',
        'z-session',
        'older',
      ]);
      expect(result.sessions.first.sets.map((s) => s.id), [
        'a-set',
        'z-set',
        'b-set',
        'sort-last',
        'number-last',
      ]);
      expect(result.stats.bestSet?.id, 'a-set');
      expect(result.stats.lastPerformed, HistoryFixture.date);
      expect(result.stats.sessionCount, 3);
    }
  });

  test(
    'initial empty history becomes complete after contributing inserts',
    () async {
      final observation = observe();
      final empty = await observation.until((h) => h.sessions.isEmpty);
      expect(empty.stats.isEmpty, isTrue);
      expect(empty.stats.heaviestWeight, isNull);
      expect(empty.stats.bestEstimatedOneRepMax, isNull);
      expect(empty.stats.bestSet, isNull);
      expect(empty.stats.lastPerformed, isNull);

      await HistoryFixture(db).workout('inserted');
      final result = await observation.until((h) => h.sessions.isNotEmpty);
      expect(result.sessions.single.sessionName, 'Push inserted');
      expect(result.sessions.single.sets.single.id, 'inserted-set');
      expect(result.stats.sessionCount, 1);
      expect(result.stats.heaviestWeight, 100);
    },
  );

  test(
    'session completion and edited weight or reps refresh without new sets',
    () async {
      await HistoryFixture(db).workout('workout', status: SessionStatus.active);
      final observation = observe();
      await observation.until((h) => h.sessions.isEmpty);
      await (db.update(
        db.workoutSessions,
      )..where((s) => s.id.equals('workout'))).write(
        const WorkoutSessionsCompanion(status: Value(SessionStatus.completed)),
      );
      await observation.until((h) => h.stats.sessionCount == 1);

      await (db.update(db.setEntries)..where((s) => s.id.equals('workout-set')))
          .write(const SetEntriesCompanion(weight: Value(150)));
      final weighted = await observation.until(
        (h) => h.stats.heaviestWeight == 150,
      );
      expect(weighted.stats.bestEstimatedOneRepMax, 200);
      await (db.update(db.setEntries)..where((s) => s.id.equals('workout-set')))
          .write(const SetEntriesCompanion(reps: Value(6)));
      final repped = await observation.until((h) => h.stats.bestSet?.reps == 6);
      expect(repped.stats.bestEstimatedOneRepMax, 180);
      expect(repped.sessions.single.bestEstimatedOneRepMax, 180);
      expect(repped.sessions.single.sets, hasLength(1));
    },
  );

  test(
    'matching follows live display names independently of template identity',
    () async {
      final fixture = HistoryFixture(db);
      await fixture.session('workout');
      await fixture.exercise(
        'first',
        'workout',
        name: 'bench PRESS',
        sourceId: 'template-a',
      );
      await fixture.exercise('second', 'workout', sourceId: 'template-b');
      await fixture.exercise(
        'other',
        'workout',
        name: 'Squat',
        sourceId: 'template-a',
      );
      await fixture.set('first-set', 'first');
      await fixture.set('second-set', 'second');
      await fixture.set('other-set', 'other', weight: 900);
      final observation = observe();
      final first = await observation.until((h) => h.sessions.isNotEmpty);
      expect(first.sessions.single.sets.map((s) => s.id), [
        'first-set',
        'second-set',
      ]);
      expect(first.stats.heaviestWeight, 100);

      await (db.update(db.sessionExercises)
            ..where((e) => e.id.equals('second')))
          .write(const SessionExercisesCompanion(displayName: Value('Squat')));
      final renamed = await observation.until(
        (h) => h.sessions.single.sets.length == 1,
      );
      expect(renamed.sessions.single.sets.single.id, 'first-set');
      final after = observation.snapshots.length;
      await (db.update(
        db.sessionExercises,
      )..where((e) => e.id.equals('second'))).write(
        const SessionExercisesCompanion(displayName: Value('BENCH press')),
      );
      final restored = await observation.until(
        (h) => h.sessions.single.sets.length == 2,
        after: after,
      );
      expect(restored.stats.sessionCount, 1);
    },
  );

  test(
    'session metadata updates names, grouping order, and last performed',
    () async {
      final fixture = HistoryFixture(db);
      await fixture.workout('older', startedAt: DateTime(2026, 1, 1));
      await fixture.workout('newer');
      final observation = observe();
      await observation.until((h) => h.sessions.length == 2);
      final newest = DateTime(2026, 2, 1);
      await (db.update(
        db.workoutSessions,
      )..where((s) => s.id.equals('older'))).write(
        WorkoutSessionsCompanion(
          name: const Value('Renamed workout'),
          startedAt: Value(newest),
        ),
      );
      final result = await observation.until(
        (h) => h.stats.lastPerformed == newest,
      );
      expect(result.sessions.map((s) => s.sessionId), ['older', 'newer']);
      expect(result.sessions.first.sessionName, 'Renamed workout');
    },
  );

  for (final rowKind in ['session', 'exercise', 'set']) {
    test(
      '$rowKind tombstone removes its records and restoration adds them',
      () async {
        final fixture = HistoryFixture(db);
        await fixture.workout('fallback', startedAt: DateTime(2026, 1, 1));
        await fixture.workout('winner');
        await (db.update(db.setEntries)
              ..where((s) => s.id.equals('winner-set')))
            .write(const SetEntriesCompanion(weight: Value(300)));
        final observation = observe();
        await observation.until((h) => h.stats.heaviestWeight == 300);

        Future<void> tombstone(DateTime? date) async {
          switch (rowKind) {
            case 'session':
              await (db.update(db.workoutSessions)
                    ..where((s) => s.id.equals('winner')))
                  .write(WorkoutSessionsCompanion(deletedAt: Value(date)));
            case 'exercise':
              await (db.update(db.sessionExercises)
                    ..where((s) => s.id.equals('winner-exercise')))
                  .write(SessionExercisesCompanion(deletedAt: Value(date)));
            case 'set':
              await (db.update(db.setEntries)
                    ..where((s) => s.id.equals('winner-set')))
                  .write(SetEntriesCompanion(deletedAt: Value(date)));
          }
        }

        await tombstone(HistoryFixture.date);
        final removed = await observation.until(
          (h) => h.stats.sessionCount == 1,
        );
        expect(removed.sessions.single.sessionId, 'fallback');
        expect(removed.stats.heaviestWeight, 100);
        expect(removed.stats.bestSet?.id, 'fallback-set');
        expect(removed.stats.bestEstimatedOneRepMax, closeTo(133.333, 0.001));
        expect(removed.stats.lastPerformed, DateTime(2026, 1, 1));
        final after = observation.snapshots.length;
        await tombstone(null);
        final restored = await observation.until(
          (h) => h.stats.heaviestWeight == 300,
          after: after,
        );
        expect(restored.stats.sessionCount, 2);
        expect(restored.stats.bestSet?.id, 'winner-set');
        expect(restored.stats.lastPerformed, HistoryFixture.date);
      },
    );
  }

  test(
    'losing and restoring eligibility refreshes history and records',
    () async {
      await HistoryFixture(db).workout('workout');
      final observation = observe();
      await observation.until((h) => h.stats.sessionCount == 1);
      Future<void> emptyAfter(Future<void> Function() write) async {
        final after = observation.snapshots.length;
        await write();
        final result = await observation.until(
          (h) => h.sessions.isEmpty,
          after: after,
        );
        expect(result.stats.sessionCount, 0);
        expect(result.stats.bestSet, isNull);
        expect(result.stats.heaviestWeight, isNull);
        expect(result.stats.bestEstimatedOneRepMax, isNull);
        expect(result.stats.lastPerformed, isNull);
      }

      Future<void> restoredAfter(Future<void> Function() write) async {
        final after = observation.snapshots.length;
        await write();
        final result = await observation.until(
          (h) => h.stats.sessionCount == 1,
          after: after,
        );
        expect(result.stats.bestSet?.id, 'workout-set');
      }

      Future<void> status(SetStatus status) async {
        await db
            .update(db.setEntries)
            .write(SetEntriesCompanion(status: Value(status)));
      }

      await emptyAfter(() => status(SetStatus.pending));
      await restoredAfter(() => status(SetStatus.completed));
      await emptyAfter(() => status(SetStatus.skipped));
      await restoredAfter(() => status(SetStatus.completed));
      await emptyAfter(() async {
        await db
            .update(db.setEntries)
            .write(const SetEntriesCompanion(completedAt: Value(null)));
      });
      await restoredAfter(() async {
        await db
            .update(db.setEntries)
            .write(
              SetEntriesCompanion(completedAt: Value(HistoryFixture.date)),
            );
      });
      await emptyAfter(() async {
        await db
            .update(db.workoutSessions)
            .write(
              const WorkoutSessionsCompanion(
                status: Value(SessionStatus.abandoned),
              ),
            );
      });
      await restoredAfter(() async {
        await db
            .update(db.workoutSessions)
            .write(
              const WorkoutSessionsCompanion(
                status: Value(SessionStatus.completed),
              ),
            );
      });
    },
  );

  test(
    'records ignore missing weight and missing or nonpositive reps',
    () async {
      final fixture = HistoryFixture(db);
      await fixture.session('workout');
      await fixture.exercise('exercise', 'workout');
      await fixture.set('no-weight', 'exercise', weight: null);
      await fixture.set('no-reps', 'exercise', weight: 200, reps: null);
      await fixture.set('zero-reps', 'exercise', weight: 300, reps: 0);
      await fixture.set('negative-reps', 'exercise', weight: 400, reps: -1);
      final incomplete = await history.watchForName('Bench Press').first;
      expect(incomplete.sessions.single.sets, hasLength(4));
      expect(incomplete.stats.heaviestWeight, 400);
      expect(incomplete.stats.bestEstimatedOneRepMax, isNull);
      expect(incomplete.stats.bestSet, isNull);
      expect(incomplete.sessions.single.bestEstimatedOneRepMax, isNull);
      expect(incomplete.stats.lastPerformed, HistoryFixture.date);
      await fixture.set('complete', 'exercise');
      final result = await history.watchForName('Bench Press').first;
      expect(result.stats.bestSet?.id, 'complete');
      expect(result.stats.bestEstimatedOneRepMax, closeTo(133.333, 0.001));
      expect(
        result.sessions.single.bestEstimatedOneRepMax,
        closeTo(133.333, 0.001),
      );
      expect(result.stats.heaviestWeight, 400);
    },
  );

  test(
    'multi-table transactions publish complete committed snapshots only',
    () async {
      await HistoryFixture(db).workout('workout');
      final observation = observe();
      final first = await observation.until((h) => h.stats.sessionCount == 1);
      await db.transaction(() async {
        await db
            .update(db.workoutSessions)
            .write(const WorkoutSessionsCompanion(name: Value('Committed')));
        await db
            .update(db.sessionExercises)
            .write(
              const SessionExercisesCompanion(
                displayName: Value('BENCH PRESS'),
              ),
            );
        // Yield while the transaction is open to expose premature emissions.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await db
            .update(db.setEntries)
            .write(
              const SetEntriesCompanion(weight: Value(150), reps: Value(6)),
            );
      });
      final committed = await observation.until(
        (h) => h.stats.heaviestWeight == 150,
      );
      expect(committed.sessions.single.sessionName, 'Committed');
      expect(committed.sessions.single.sets.single.reps, 6);
      expect(committed.stats.bestEstimatedOneRepMax, 180);
      for (final result in observation.snapshots) {
        expect(
          [
            result.sessions.single.sessionName,
            result.sessions.single.sets.single.weight,
            result.sessions.single.sets.single.reps,
            result.stats.bestEstimatedOneRepMax,
          ],
          anyOf(
            equals([
              first.sessions.single.sessionName,
              100.0,
              10,
              first.stats.bestEstimatedOneRepMax,
            ]),
            equals(['Committed', 150.0, 6, 180.0]),
          ),
        );
      }
      final count = observation.snapshots.length;
      await expectLater(
        db.transaction(() async {
          await db
              .update(db.workoutSessions)
              .write(
                const WorkoutSessionsCompanion(name: Value('Rolled back')),
              );
          await db
              .update(db.setEntries)
              .write(const SetEntriesCompanion(weight: Value(900)));
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (final result in observation.snapshots.skip(count)) {
        expect(result.sessions.single.sessionName, 'Committed');
        expect(result.stats.heaviestWeight, 150);
        expect(result.stats.bestEstimatedOneRepMax, 180);
      }
      final fresh = await history.watchForName('Bench Press').first;
      expect(fresh.sessions.single.sessionName, 'Committed');
      expect(fresh.stats.heaviestWeight, 150);
    },
  );

  test('database failures reach history observation', () async {
    final control = HistoryReadControl();
    await db.close();
    db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(control),
    );
    await HistoryFixture(db).workout('workout');
    final failure = StateError('history read failed');
    control.failure = failure;
    await expectLater(
      ExerciseHistoryService(db).watchForName('Bench Press').first,
      throwsA(same(failure)),
    );
  });

  test('cancelling history observation stops later results', () async {
    await HistoryFixture(db).workout('workout');
    final snapshots = <ExerciseHistory>[];
    final initial = Completer<void>();
    final subscription = history.watchForName('Bench Press').listen((result) {
      snapshots.add(result);
      if (!initial.isCompleted) initial.complete();
    });
    await initial.future;
    await subscription.cancel();
    await db
        .update(db.setEntries)
        .write(const SetEntriesCompanion(weight: Value(200)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(snapshots, hasLength(1));
    expect(snapshots.single.stats.heaviestWeight, 100);
    // A new observer sees committed data rather than a retained stale result.
    expect(
      (await history.watchForName('Bench Press').first).stats.heaviestWeight,
      200,
    );
  });
}
