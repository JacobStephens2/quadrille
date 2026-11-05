import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';

// Compare all observable snapshots and values, including optional references.
List<Object?> contents(List<SessionGridRow> grid) => [
  for (final row in grid)
    [row.exercise, row.sets, row.previous?.exercise, row.previousSets],
];

class GridObservation {
  GridObservation(Stream<List<SessionGridRow>> stream) {
    _subscription = stream.listen((grid) {
      emissions.add(grid);
      _events.add(grid);
    }, onError: _events.addError);
  }

  final emissions = <List<SessionGridRow>>[];
  final _events = StreamController<List<SessionGridRow>>.broadcast(sync: true);
  late final StreamSubscription<List<SessionGridRow>> _subscription;

  Future<List<SessionGridRow>> until(
    bool Function(List<SessionGridRow>) predicate, {
    int after = 0,
  }) async {
    for (final grid in emissions.skip(after).toList().reversed) {
      if (predicate(grid)) return grid;
    }
    return _events.stream
        .firstWhere(predicate)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _events.close();
  }
}

void main() {
  late QuadrilleDatabase db;
  late SessionRepository sessions;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    sessions = SessionRepository(db);
  });
  tearDown(() => db.close());

  Future<void> seed(String id, int day, {bool completed = false}) async {
    final date = DateTime(2026, 1, day);
    await db
        .into(db.workoutSessions)
        .insert(
          WorkoutSessionsCompanion.insert(
            id: id,
            name: 'Push A',
            status: Value(
              completed ? SessionStatus.completed : SessionStatus.active,
            ),
            startedAt: date,
            completedAt: Value(completed ? date : null),
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
            sourceTemplateExerciseId: const Value('bench-row'),
            displayName: 'Bench Press',
            orderLabel: '1',
            sortIndex: 10,
            createdAt: date,
            updatedAt: date,
          ),
        );
    // Deliberately insert out of order.
    for (final number in [3, 1, 4, 2]) {
      await db
          .into(db.setEntries)
          .insert(
            SetEntriesCompanion.insert(
              id: '$id-$number',
              sessionExerciseId: '$id-exercise',
              setNumber: number,
              createdAt: date,
              updatedAt: date,
            ),
          );
    }
  }

  GridObservation observe(String id) {
    final observation = GridObservation(sessions.watchGrid(id));
    addTearDown(observation.close);
    return observation;
  }

  test(
    'fresh and first watched grids include the same complete history',
    () async {
      await seed('previous', 1, completed: true);
      await sessions.saveSet('previous-1', weight: 70, reps: 10);
      await seed('current', 10);
      await sessions.saveSet(
        'current-2',
        status: SetStatus.skipped,
        notes: 'skip',
      );
      await sessions.saveSet(
        'current-3',
        weight: 20,
        reps: 5,
        status: SetStatus.warmup,
      );
      await sessions.saveSet(
        'current-4',
        weight: 75,
        reps: 8,
        rpe: 9,
        partials: 2,
      );

      // Fresh reads need no subscription to make historical defaults available.
      final fresh = await sessions.readGrid('current');
      final first = await sessions.watchGrid('current').first;

      expect(contents(first), contents(fresh));
      expect(first.single.previous!.exercise.id, 'previous-exercise');
      expect(first.single.previousSets.single.weight, 70);
      expect(first.single.prefillWeightFor(first.single.sets.first), 70);
      expect(first.single.sets.map((set) => set.setNumber), [1, 2, 3, 4]);
      expect(first.single.sets.map((set) => set.status), [
        SetStatus.pending,
        SetStatus.skipped,
        SetStatus.warmup,
        SetStatus.completed,
      ]);
      expect(first.single.sets[1].notes, 'skip');
      expect(first.single.sets[2].weight, 20);
      expect(first.single.sets[2].reps, 5);
      expect(first.single.sets[3].rpe, 9);
      expect(first.single.sets[3].partials, 2);
    },
  );

  test('missing, empty, and tombstoned sessions have empty grids', () async {
    expect(await sessions.readGrid('missing'), isEmpty);
    expect(await sessions.watchGrid('missing').first, isEmpty);
    await seed('current', 10);
    await (db.delete(
      db.sessionExercises,
    )..where((exercise) => exercise.sessionId.equals('current'))).go();
    expect(await sessions.readGrid('current'), isEmpty);
    expect(await sessions.watchGrid('current').first, isEmpty);
    await seed('deleted', 11);
    await (db.update(
      db.workoutSessions,
    )..where((s) => s.id.equals('deleted'))).write(
      WorkoutSessionsCompanion(deletedAt: Value(DateTime(2026, 1, 12))),
    );
    expect(await sessions.readGrid('deleted'), isEmpty);
    expect(await sessions.watchGrid('deleted').first, isEmpty);
  });

  test(
    'exercise and set tombstones preserve live rows and sheet order',
    () async {
      await seed('current', 10);
      final original = (await sessions.readGrid('current')).single.exercise;
      for (final (id, order, deleted) in [
        ('last', 30, false),
        ('first', 0, false),
        ('hidden', 20, true),
      ]) {
        await db
            .into(db.sessionExercises)
            .insert(
              original.copyWith(
                id: id,
                sortIndex: order,
                deletedAt: Value(deleted ? DateTime(2026) : null),
              ),
            );
      }
      await sessions.deleteSet('current-2');
      final grid = await sessions.readGrid('current');
      expect(grid.map((row) => row.exercise.id), [
        'first',
        'current-exercise',
        'last',
      ]);
      expect(grid.first.sets, isEmpty);
      expect(grid.last.sets, isEmpty);
      expect(grid[1].sets.map((set) => set.setNumber), [1, 3, 4]);
      expect(
        contents(await sessions.watchGrid('current').first),
        contents(grid),
      );
    },
  );

  test(
    'every emission is coherent across current and historical transactions',
    () async {
      await seed('previous', 1, completed: true);
      await sessions.saveSet('previous-1', weight: 70, reps: 10);
      await seed('current', 10);
      final observation = observe('current');
      final before = await observation.until((grid) => grid.isNotEmpty);

      await db.transaction(() async {
        await (db.update(
          db.sessionExercises,
        )..where((e) => e.id.equals('current-exercise'))).write(
          const SessionExercisesCompanion(displayName: Value('Renamed')),
        );
        await sessions.saveSet('current-1', weight: 80, reps: 8);
        await sessions.saveSet('previous-1', weight: 75, reps: 9);
      });
      final after = await observation.until(
        (grid) => grid.single.exercise.displayName == 'Renamed',
      );
      expect(after.single.sets.first.weight, 80);
      expect(after.single.previousSets.single.weight, 75);
      expect(after.single.previousSets.single.reps, 9);
      expect(contents(await sessions.readGrid('current')), contents(after));
      for (final grid in observation.emissions) {
        expect(
          contents(grid),
          anyOf(equals(contents(before)), equals(contents(after))),
        );
      }
    },
  );

  test(
    'watch follows session creation and current tombstones at commit boundaries',
    () async {
      final observation = observe('current');
      expect(await observation.until((grid) => grid.isEmpty), isEmpty);
      await db.transaction(() => seed('current', 10));
      final created = await observation.until((grid) => grid.isNotEmpty);
      expect(created.single.sets, hasLength(4));

      await db.transaction(() async {
        for (var number = 1; number <= 4; number++) {
          await sessions.deleteSet('current-$number');
        }
      });
      final emptyRow = await observation.until(
        (grid) => grid.isNotEmpty && grid.single.sets.isEmpty,
      );
      expect(emptyRow.single.exercise.id, 'current-exercise');
      var start = observation.emissions.length;
      await (db.update(db.sessionExercises)
            ..where((e) => e.id.equals('current-exercise')))
          .write(SessionExercisesCompanion(deletedAt: Value(DateTime(2026))));
      expect(
        await observation.until((grid) => grid.isEmpty, after: start),
        isEmpty,
      );

      await db.transaction(() async {
        await (db.update(db.sessionExercises)
              ..where((e) => e.id.equals('current-exercise')))
            .write(const SessionExercisesCompanion(deletedAt: Value(null)));
        await (db.update(db.setEntries)..where((s) => s.id.equals('current-1')))
            .write(const SetEntriesCompanion(deletedAt: Value(null)));
      });
      final restored = await observation.until(
        (grid) => grid.isNotEmpty && grid.single.sets.length == 1,
      );
      expect(restored.single.sets.single.id, 'current-1');
      start = observation.emissions.length;
      await (db.update(db.workoutSessions)
            ..where((s) => s.id.equals('current')))
          .write(WorkoutSessionsCompanion(deletedAt: Value(DateTime(2026))));
      expect(
        await observation.until((grid) => grid.isEmpty, after: start),
        isEmpty,
      );
      expect(await sessions.readGrid('current'), isEmpty);
      for (final grid in observation.emissions) {
        expect(
          contents(grid),
          anyOf([
            equals([]),
            equals(contents(created)),
            equals(contents(emptyRow)),
            equals(contents(restored)),
          ]),
        );
      }
    },
  );

  test(
    'watch reselects references for historical eligibility and deletion changes',
    () async {
      await seed('older', 1, completed: true);
      await sessions.saveSet('older-1', weight: 60, reps: 10);
      await seed('latest', 2, completed: true);
      await sessions.saveSet('latest-1', weight: 70, reps: 8);
      await seed('current', 10);
      final observation = observe('current');
      final allowed = <List<Object?>>[];
      allowed.add(contents(await observation.until((grid) => grid.isNotEmpty)));

      Future<void> change(
        Future<void> Function() write,
        String? reference,
        double? weight,
      ) async {
        final start = observation.emissions.length;
        await write();
        final grid = await observation.until(
          (grid) =>
              grid.single.previous?.exercise.id == reference &&
              grid.single.previousSets.firstOrNull?.weight == weight,
          after: start,
        );
        allowed.add(contents(grid));
        expect(contents(await sessions.readGrid('current')), contents(grid));
      }

      await change(
        () => sessions.saveSet('latest-1', weight: 75, reps: 9),
        'latest-exercise',
        75,
      );
      await change(
        () async {
          await (db.update(
            db.workoutSessions,
          )..where((s) => s.id.equals('latest'))).write(
            WorkoutSessionsCompanion(completedAt: Value(DateTime(2026, 1, 11))),
          );
        },
        'older-exercise',
        60,
      );
      await change(
        () async {
          await (db.update(
            db.workoutSessions,
          )..where((s) => s.id.equals('latest'))).write(
            WorkoutSessionsCompanion(completedAt: Value(DateTime(2026, 1, 10))),
          );
        },
        'latest-exercise',
        75,
      );
      await change(
        () async {
          await (db.update(
            db.workoutSessions,
          )..where((s) => s.id.equals('latest'))).write(
            const WorkoutSessionsCompanion(status: Value(SessionStatus.active)),
          );
        },
        'older-exercise',
        60,
      );
      await change(
        () async {
          await (db.update(
            db.sessionExercises,
          )..where((e) => e.id.equals('older-exercise'))).write(
            SessionExercisesCompanion(deletedAt: Value(DateTime(2026))),
          );
        },
        null,
        null,
      );
      await change(
        () async {
          await (db.update(
            db.workoutSessions,
          )..where((s) => s.id.equals('latest'))).write(
            const WorkoutSessionsCompanion(
              status: Value(SessionStatus.completed),
            ),
          );
        },
        'latest-exercise',
        75,
      );
      await change(
        () => sessions.deleteSet('latest-1'),
        'latest-exercise',
        null,
      );
      await change(
        () async {
          await (db.update(
            db.workoutSessions,
          )..where((s) => s.id.equals('latest'))).write(
            WorkoutSessionsCompanion(deletedAt: Value(DateTime(2026))),
          );
        },
        null,
        null,
      );
      for (final grid in observation.emissions) {
        expect(contents(grid), anyOf(allowed.map(equals).toList()));
      }
    },
  );

  test(
    'watch refreshes after multi-table sync merges without mixed emissions',
    () async {
      await seed('previous', 1, completed: true);
      await sessions.saveSet('previous-1', weight: 70, reps: 10);
      await seed('current', 10);
      final backup = BackupService(db);
      final payload = await backup.exportSyncPayload();
      final rows = payload['tables'] as Map<String, dynamic>;
      final stamp = DateTime(2027).millisecondsSinceEpoch;
      for (final row in rows['sessionExercises'] as List<dynamic>) {
        final exercise = row as Map<String, dynamic>;
        exercise['displayName'] = 'Synced';
        exercise['updatedAt'] = stamp;
      }
      for (final row in rows['setEntries'] as List<dynamic>) {
        final set = row as Map<String, dynamic>;
        if (set['id'] == 'previous-1') set['weight'] = 90.0;
        if (set['id'] == 'current-2') set['deletedAt'] = stamp;
        set['updatedAt'] = stamp;
      }
      for (final row in rows['workoutSessions'] as List<dynamic>) {
        final session = row as Map<String, dynamic>;
        if (session['id'] == 'previous') {
          session['completedAt'] = DateTime(2026, 1, 3).millisecondsSinceEpoch;
          session['updatedAt'] = stamp;
        }
      }
      final observation = observe('current');
      final before = await observation.until((grid) => grid.isNotEmpty);
      await backup.mergeIntoLocal(payload);
      final after = await observation.until(
        (grid) => grid.single.exercise.displayName == 'Synced',
      );
      expect(after.single.previousSets.single.weight, 90);
      expect(after.single.sets.map((set) => set.setNumber), [1, 3, 4]);
      for (final grid in observation.emissions) {
        expect(
          contents(grid),
          anyOf(equals(contents(before)), equals(contents(after))),
        );
      }
    },
  );
}
