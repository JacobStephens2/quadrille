import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/data/session_repository.dart';

void main() {
  late QuadrilleDatabase db;
  late SessionRepository sessions;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    sessions = SessionRepository(db);
  });
  tearDown(() => db.close());

  Future<void> seedSession(
    String id,
    int day, {
    String? source = 'bench-row',
    String name = 'Bench Press',
    SessionStatus status = SessionStatus.completed,
    bool deleted = false,
    bool exerciseDeleted = false,
    int? completedDay,
  }) async {
    final date = DateTime(2026, 1, day);
    await db
        .into(db.workoutSessions)
        .insert(
          WorkoutSessionsCompanion.insert(
            id: id,
            name: 'Push A',
            status: Value(status),
            startedAt: date,
            completedAt: Value(
              status == SessionStatus.completed
                  ? DateTime(2026, 1, completedDay ?? day)
                  : null,
            ),
            deletedAt: Value(deleted ? date : null),
            createdAt: date,
            updatedAt: date,
          ),
        );
    await db
        .into(db.sessionExercises)
        .insert(
          SessionExercisesCompanion.insert(
            id: '$id-exercise',
            sessionId: id,
            sourceTemplateExerciseId: Value(source),
            displayName: name,
            orderLabel: '1',
            sortIndex: 10,
            plannedSets: const Value(3),
            deletedAt: Value(exerciseDeleted ? date : null),
            createdAt: date,
            updatedAt: date,
          ),
        );
    for (var number = 1; number <= 3; number++) {
      final setId = '$id-$number';
      await db
          .into(db.setEntries)
          .insert(
            SetEntriesCompanion.insert(
              id: setId,
              sessionExerciseId: '$id-exercise',
              setNumber: number,
              createdAt: date,
              updatedAt: date,
            ),
          );
      await sessions.saveSet(setId, weight: 70, reps: 10);
    }
  }

  Future<void> seedActive({String? source = 'bench-row'}) =>
      seedSession('active', 10, source: source, status: SessionStatus.active);

  test(
    'matching template row takes priority over a newer name match',
    () async {
      await seedSession('same-source', 1, name: 'Original name');
      await seedSession('same-name', 2, source: 'other-row');
      await seedActive();

      final history = await sessions.watchPreviousExercises('active').first;

      expect(history['active-exercise']!.exercise.id, 'same-source-exercise');
    },
  );

  test(
    'name fallback chooses the newest match even without a source ID',
    () async {
      await seedSession('older', 1, source: 'other-row');
      await seedSession('newer', 2, source: null);
      await seedActive();

      final history = await sessions.watchPreviousExercises('active').first;

      expect(history['active-exercise']!.exercise.id, 'newer-exercise');
    },
  );

  test('an exercise without a source ID falls back by name', () async {
    await seedSession('previous', 1);
    await seedActive(source: null);

    final history = await sessions.watchPreviousExercises('active').first;

    expect(history['active-exercise']!.exercise.id, 'previous-exercise');
  });

  test('latest completion wins among matches for the same row', () async {
    await seedSession('older-start', 1, completedDay: 4);
    await seedSession('newer-start', 2, completedDay: 3);
    await seedActive();

    final history = await sessions.watchPreviousExercises('active').first;

    expect(history['active-exercise']!.exercise.id, 'older-start-exercise');
  });

  test('only prior completed and live history is eligible', () async {
    await seedSession('previous', 1);
    await seedSession('unfinished', 2, status: SessionStatus.active);
    await seedSession('abandoned', 3, status: SessionStatus.abandoned);
    await seedSession('deleted-session', 4, deleted: true);
    await seedSession('deleted-exercise', 5, exerciseDeleted: true);
    await seedSession('finished-later', 6, completedDay: 11);
    await seedSession('future', 12);
    await seedActive();

    final history = await sessions.watchPreviousExercises('active').first;

    expect(history['active-exercise']!.exercise.id, 'previous-exercise');
  });

  test('pending skipped warmup and deleted sets are omitted', () async {
    await seedSession('previous', 1);
    await sessions.saveSet('previous-1', status: SetStatus.pending);
    await sessions.saveSet('previous-2', status: SetStatus.skipped);
    await sessions.saveSet('previous-3', status: SetStatus.warmup);
    final bonus = await sessions.addSet('previous-exercise');
    await sessions.saveSet(bonus, weight: 70, reps: 10);
    await sessions.deleteSet(bonus);
    await seedActive();

    final history = await sessions.watchPreviousExercises('active').first;

    expect(history['active-exercise']!.exercise.id, 'previous-exercise');
    expect(history['active-exercise']!.sets, isEmpty);
  });

  test(
    'an empty latest exercise does not borrow an older performance',
    () async {
      await seedSession('older', 1);
      await seedSession('latest', 2);
      for (var number = 1; number <= 3; number++) {
        await sessions.saveSet('latest-$number', status: SetStatus.skipped);
      }
      await seedActive();

      final history = await sessions.watchPreviousExercises('active').first;

      expect(history['active-exercise']!.exercise.id, 'latest-exercise');
      expect(history['active-exercise']!.sets, isEmpty);
    },
  );

  test('no matching history leaves the reference empty', () async {
    await seedSession('unrelated', 1, name: 'Squat', source: 'squat-row');
    await seedActive();

    expect(await sessions.watchPreviousExercises('active').first, isEmpty);
  });

  test('history stream updates when a previous set is edited', () async {
    await seedSession('previous', 1);
    await seedActive();
    final stream = sessions.watchPreviousExercises('active');
    final updated = stream.firstWhere(
      (history) => history['active-exercise']?.sets.first.weight == 75,
    );

    await sessions.saveSet('previous-1', weight: 75, reps: 8);

    expect((await updated)['active-exercise']!.sets.first.reps, 8);
  });
}
