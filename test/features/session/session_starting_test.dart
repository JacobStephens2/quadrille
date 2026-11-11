import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/session/session_starting.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

import 'session_starting_fixture.dart';

void main() {
  late StartingFixture fixture;

  setUp(() async {
    fixture = StartingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  test(
    'same-template starts share pending work and its result, then permit reuse',
    () async {
      final handle = fixture.container.read(
        sessionStartingProvider(StartingFixture.templateId),
      );
      final gate = StartingWait();
      fixture.aRepository.waiting = gate;
      final observed = <bool>[];
      handle.addListener(() => observed.add(handle.isPending));
      final first = handle.start();
      final second = handle.start();
      expect(second, same(first));
      expect(handle.isPending, isTrue);
      await gate.entered.future;
      expect(fixture.aRepository.submissions, 1);
      gate.completion.complete();
      final result = await first;
      expect(await second, same(result));
      expect(result.status, SessionStartingStatus.started);
      expect(result.sessionId, isNotNull);
      expect(handle.isPending, isFalse);
      expect(observed, [true, false]);
      final later = await handle.start();
      expect(later.status, SessionStartingStatus.started);
      expect(later.sessionId, isNot(result.sessionId));
    },
  );

  test('pending is claimed before listeners re-enter the handle', () async {
    final handle = fixture.container.read(
      sessionStartingProvider(StartingFixture.templateId),
    );
    Future<SessionStartingOutcome>? reentrant;
    handle.addListener(() {
      if (handle.isPending) reentrant = handle.start();
    });
    final operation = handle.start();
    expect(reentrant, same(operation));
    expect((await operation).status, SessionStartingStatus.started);
    expect(fixture.aRepository.submissions, 1);
  });

  test(
    'current failure settles safely and a deliberate retry creates a workout',
    () async {
      final handle = fixture.container.read(
        sessionStartingProvider(StartingFixture.templateId),
      );
      fixture.aRepository.fail = true;
      final failure = await handle.start();
      expect(failure.status, SessionStartingStatus.failed);
      expect(failure.error, isA<StateError>());
      expect(failure.sessionId, isNull);
      expect(handle.isPending, isFalse);
      fixture.aRepository.fail = false;
      final retry = await handle.start();
      expect(retry.status, SessionStartingStatus.started);
      expect(
        await fixture.aRepository.watchSession(retry.sessionId!).first,
        isNotNull,
      );
    },
  );

  test('different templates can start while one is delayed', () async {
    final otherId = await TemplateRepository(
      fixture.a,
    ).createTemplate(name: 'Pull A');
    final gate = StartingWait();
    fixture.aRepository.waiting = gate;
    final first = fixture.container
        .read(sessionStartingProvider(StartingFixture.templateId))
        .start();
    await gate.entered.future;
    fixture.aRepository.waiting = null;
    final other = await fixture.container
        .read(sessionStartingProvider(otherId))
        .start();
    expect(other.status, SessionStartingStatus.started);
    expect(
      (await fixture.aRepository.watchSession(other.sessionId!).first)!.name,
      'Pull A',
    );
    gate.completion.complete();
    expect((await first).sessionId, isNot(other.sessionId));
  });

  for (final retirement in [
    'profile',
    'round trip',
    'database',
    'repository',
    'provider',
    'disposal',
  ]) {
    test(
      '$retirement permanently retires a retained handle before submission',
      () async {
        final handle = fixture.container.read(
          sessionStartingProvider(StartingFixture.templateId),
        );
        final original = fixture.aRepository;
        switch (retirement) {
          case 'profile':
            fixture.switchTo('b');
          case 'round trip':
            fixture.switchTo('b');
            fixture.switchTo('a');
          case 'database':
            fixture.a = await fixture.addDatabase();
            fixture.aRepository = StartingRepository(fixture.a);
            fixture.container.invalidate(databaseProvider);
          case 'repository':
            fixture.aRepository = StartingRepository(fixture.a);
            fixture.container.invalidate(sessionRepositoryProvider);
          case 'provider':
            fixture.container.invalidate(
              sessionStartingProvider(StartingFixture.templateId),
            );
          case 'disposal':
            fixture.disposeOwner();
        }
        expect(handle.isCurrent, isFalse);
        expect((await handle.start()).status, SessionStartingStatus.superseded);
        expect(original.submissions, 0);
        expect(handle.isPending, isFalse);
        if (retirement != 'disposal') {
          final fresh = fixture.container.read(
            sessionStartingProvider(StartingFixture.templateId),
          );
          expect(fresh, isNot(same(handle)));
          expect(fresh.isCurrent, isTrue);
          expect(handle.isCurrent, isFalse);
          expect((await fresh.start()).status, SessionStartingStatus.started);
        }
      },
    );
  }

  for (final fails in [false, true]) {
    test(
      'accepted work stays in its captured database and supersedes ${fails ? 'failure' : 'success'}',
      () async {
        final handle = fixture.container.read(
          sessionStartingProvider(StartingFixture.templateId),
        );
        final gate = StartingWait();
        fixture.aRepository.waiting = gate;
        fixture.aRepository.fail = fails;
        final oldWork = handle.start();
        await gate.entered.future;
        fixture.switchTo('b');
        final fresh = fixture.container.read(
          sessionStartingProvider(StartingFixture.templateId),
        );
        final current = await fresh.start();
        expect(current.status, SessionStartingStatus.started);
        expect(fresh.isPending, isFalse);
        gate.completion.complete();
        final obsolete = await oldWork;
        expect(obsolete.status, SessionStartingStatus.superseded);
        expect(obsolete.sessionId, isNull);
        expect(obsolete.error, isNull);
        expect(handle.isPending, isFalse);
        expect(
          await SessionRepository(fixture.a).watchActiveSession().first,
          fails ? isNull : isNotNull,
        );
        expect(
          (await fixture.bRepository.watchActiveSession().first)!.id,
          current.sessionId,
        );
      },
    );
  }

  test(
    'container disposal settles accepted persistence without notifying disposed listeners',
    () async {
      final handle = fixture.container.read(
        sessionStartingProvider(StartingFixture.templateId),
      );
      final gate = StartingWait();
      fixture.aRepository.waiting = gate;
      var notifications = 0;
      void listener() => notifications++;
      handle.addListener(listener);
      final operation = handle.start();
      await gate.entered.future;
      fixture.disposeOwner();
      expect(handle.isCurrent, isFalse);
      gate.completion.complete();
      expect((await operation).status, SessionStartingStatus.superseded);
      expect(handle.isPending, isFalse);
      expect(notifications, 1);
      handle.removeListener(listener);
      expect(await fixture.aRepository.watchActiveSession().first, isNotNull);
    },
  );

  for (final replacement in ['round trip', 'database', 'repository']) {
    test(
      '$replacement gives a fresh owner work while captured persistence waits',
      () async {
        final capturedDatabase = fixture.a;
        final capturedRepository = fixture.aRepository;
        final handle = fixture.container.read(
          sessionStartingProvider(StartingFixture.templateId),
        );
        final gate = StartingWait();
        capturedRepository.waiting = gate;
        final accepted = handle.start();
        await gate.entered.future;
        switch (replacement) {
          case 'round trip':
            fixture.switchTo('b');
            fixture.switchTo('a');
            capturedRepository.waiting = null;
          case 'database':
            fixture.a = await fixture.addDatabase();
            fixture.aRepository = StartingRepository(fixture.a);
            fixture.container.invalidate(databaseProvider);
          case 'repository':
            fixture.aRepository = StartingRepository(fixture.a);
            fixture.container.invalidate(sessionRepositoryProvider);
        }
        final fresh = fixture.container.read(
          sessionStartingProvider(StartingFixture.templateId),
        );
        final current = await fresh.start();
        expect(current.status, SessionStartingStatus.started);
        expect(handle.isCurrent, isFalse);
        gate.completion.complete();
        expect((await accepted).status, SessionStartingStatus.superseded);
        final capturedSessions = await capturedDatabase
            .select(capturedDatabase.workoutSessions)
            .get();
        expect(capturedSessions, hasLength(replacement == 'database' ? 1 : 2));
        expect(
          capturedSessions.any((session) => session.id != current.sessionId),
          isTrue,
        );
        expect(
          await fixture.aRepository.watchSession(current.sessionId!).first,
          isNotNull,
        );
        expect(await fixture.bRepository.watchActiveSession().first, isNull);
      },
    );
  }

  test(
    'retirement from a pending listener prevents repository submission',
    () async {
      final handle = fixture.container.read(
        sessionStartingProvider(StartingFixture.templateId),
      );
      handle.addListener(() {
        if (handle.isPending) fixture.switchTo('b');
      });
      expect((await handle.start()).status, SessionStartingStatus.superseded);
      expect(fixture.aRepository.submissions, 0);
      expect(fixture.bRepository.submissions, 0);
    },
  );

  test(
    'start snapshots ordered plans, notes, settings units and pending sets',
    () async {
      final templates = TemplateRepository(fixture.a);
      // Insert out of sheet order; the snapshot must keep the planned order.
      await templates.addExercise(
        StartingFixture.templateId,
        TemplateExerciseDraft(
          displayName: 'Carry',
          orderLabel: '2B',
          targetSets: 2,
          repTarget: RepTarget.duration(30, 60),
          restSeconds: 90,
          notes: 'One side at a time',
          isUnilateral: true,
          loadKind: LoadKind.timeOnly,
        ),
      );
      await templates.addExercise(
        StartingFixture.templateId,
        TemplateExerciseDraft(
          displayName: 'Fly',
          orderLabel: '2A',
          targetSets: 1,
          repTarget: RepTarget.reps(12, 15),
        ),
      );
      await fixture.a
          .update(fixture.a.appSettingsTable)
          .write(const AppSettingsTableCompanion(units: Value(WeightUnit.kg)));
      final result = await fixture.container
          .read(sessionStartingProvider(StartingFixture.templateId))
          .start();
      final session = (await fixture.aRepository
          .watchSession(result.sessionId!)
          .first)!;
      expect(session.name, 'Push A');
      expect(session.generalNotes, 'Warm up first');
      expect(session.templateId, StartingFixture.templateId);
      final grid = await fixture.aRepository.readGrid(session.id);
      expect(grid.map((row) => row.exercise.displayName), [
        'Bench Press',
        'Fly',
        'Carry',
      ]);
      final press = grid.first.exercise;
      expect(
        [
          press.orderLabel,
          press.sortIndex,
          press.repMin,
          press.repMax,
          press.plannedRestSeconds,
          press.plannedNotes,
        ],
        ['1', 100, 6, 8, 180, 'Slow eccentric'],
      );
      final carry = grid.last.exercise;
      expect(
        [
          carry.orderLabel,
          carry.supersetGroup,
          carry.plannedSets,
          carry.durationMinSeconds,
          carry.durationMaxSeconds,
          carry.plannedRestSeconds,
          carry.plannedNotes,
          carry.isUnilateral,
          carry.loadKind,
        ],
        [
          '2B',
          '2',
          2,
          30,
          60,
          90,
          'One side at a time',
          true,
          LoadKind.timeOnly,
        ],
      );
      expect(
        grid
            .map((row) => row.sets.map((set) => set.setNumber).toList())
            .toList(),
        [
          [1, 2, 3],
          [1],
          [1, 2],
        ],
      );
      for (final set in grid.expand((row) => row.sets)) {
        expect(set.status, SetStatus.pending);
        expect(set.weightUnit, WeightUnit.kg);
        expect(set.weight, isNull);
        expect(set.reps, isNull);
        expect(set.completedAt, isNull);
      }
      await templates.updateTemplate(
        StartingFixture.templateId,
        name: 'Renamed',
        notes: 'Changed',
      );
      await templates.updateExercise(
        'press',
        StartingFixture.templateId,
        TemplateExerciseDraft(
          displayName: 'Changed',
          orderLabel: '1',
          targetSets: 99,
        ),
      );
      expect(
        (await fixture.aRepository.watchSession(session.id).first)!.name,
        'Push A',
      );
      expect(
        (await fixture.aRepository.watchSession(session.id).first)!
            .generalNotes,
        'Warm up first',
      );
      expect(
        (await fixture.aRepository.readGrid(session.id)).first.sets,
        hasLength(3),
      );
      expect(
        (await fixture.aRepository.readGrid(
          session.id,
        )).first.exercise.displayName,
        'Bench Press',
      );
    },
  );

  test(
    'snapshot failure rolls back the workout, exercise and sets and permits retry',
    () async {
      await fixture.a.customStatement('''
      CREATE TRIGGER fail_set BEFORE INSERT ON set_entries
      WHEN NEW.set_number = 2
      BEGIN SELECT RAISE(ABORT, 'Snapshot set failed'); END
    ''');
      final handle = fixture.container.read(
        sessionStartingProvider(StartingFixture.templateId),
      );
      final result = await handle.start();
      expect(result.status, SessionStartingStatus.failed);
      expect(result.error.toString(), contains('Snapshot set failed'));
      expect(await fixture.aRepository.watchActiveSession().first, isNull);
      // Rollback also leaves no orphan snapshot rows after the first Set insert.
      expect(await fixture.a.select(fixture.a.workoutSessions).get(), isEmpty);
      expect(await fixture.a.select(fixture.a.sessionExercises).get(), isEmpty);
      expect(await fixture.a.select(fixture.a.setEntries).get(), isEmpty);
      expect(handle.isPending, isFalse);
      await fixture.a.customStatement('DROP TRIGGER fail_set');
      final retry = await handle.start();
      expect(retry.status, SessionStartingStatus.started);
      expect(
        (await fixture.aRepository.readGrid(retry.sessionId!)).single.sets,
        hasLength(3),
      );
    },
  );
}
