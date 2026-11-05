import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/exercises/domain/exercise_history.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';

import 'history_fixture.dart';

void main() {
  late HistoryReadControl control;
  late QuadrilleDatabase db;
  late ProviderContainer container;
  final provider = exerciseHistoryProvider('bench PRESS');

  setUp(() async {
    control = HistoryReadControl();
    db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(control),
    );
    await HistoryFixture(db).workout('session', status: SessionStatus.active);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    if (!control.release.isCompleted) control.release.complete();
    container.dispose();
    await db.close();
  });

  test('an open history refreshes after a session-only completion', () async {
    final updated = Completer<ExerciseHistory>();
    final states = <AsyncValue<ExerciseHistory>>[];
    container.listen(provider, (_, next) {
      states.add(next);
      if (next.hasValue &&
          next.requireValue.stats.sessionCount == 1 &&
          !updated.isCompleted) {
        updated.complete(next.requireValue);
      }
    }, fireImmediately: true);
    expect(states.single.isLoading, isTrue);
    final first = await container.read(provider.future);
    expect(first.sessions, isEmpty);
    // Drain any initial notifications before the session-only write.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await db
        .update(db.workoutSessions)
        .write(
          const WorkoutSessionsCompanion(
            status: Value(SessionStatus.completed),
          ),
        );

    final history = await updated.future.timeout(const Duration(seconds: 3));
    expect(history.sessions.single.sets.single.id, 'session-set');
    expect(history.stats.heaviestWeight, 100);
    expect(history.stats.bestEstimatedOneRepMax, closeTo(133.333, 0.001));
    expect(states.last.requireValue, same(history));
  });

  test('initial database errors reach the provider error state', () async {
    final failure = StateError('history read failed');
    control.failure = failure;
    final states = <AsyncValue<ExerciseHistory>>[];
    container.listen(
      provider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );
    expect(states.single.isLoading, isTrue);

    await expectLater(container.read(provider.future), throwsA(same(failure)));

    expect(states.last.hasError, isTrue);
    expect(states.last.error, same(failure));
  });

  test('database errors after a result also reach the provider', () async {
    final failed = Completer<Object>();
    container.listen(provider, (_, next) {
      if (next.hasError && !failed.isCompleted) failed.complete(next.error!);
    });
    await container.read(provider.future);
    final failure = StateError('live history read failed');
    control.failure = failure;
    await db
        .update(db.workoutSessions)
        .write(
          const WorkoutSessionsCompanion(
            status: Value(SessionStatus.completed),
          ),
        );

    expect(
      await failed.future.timeout(const Duration(seconds: 3)),
      same(failure),
    );
    expect(container.read(provider).hasError, isTrue);
    expect(container.read(provider).isLoading, isFalse);
  });

  test('disposing the provider stops subsequent history delivery', () async {
    final states = <AsyncValue<ExerciseHistory>>[];
    container.listen(provider, (_, next) => states.add(next));
    await container.read(provider.future);
    container.dispose();
    final count = states.length;
    await db
        .update(db.workoutSessions)
        .write(
          const WorkoutSessionsCompanion(
            status: Value(SessionStatus.completed),
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(states, hasLength(count));
    container = ProviderContainer();
  });

  test(
    'Local profile replacement rejects delayed results and later old changes',
    () async {
      await db
          .update(db.workoutSessions)
          .write(
            const WorkoutSessionsCompanion(
              status: Value(SessionStatus.completed),
            ),
          );
      final nextDb = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(nextDb.close);
      await HistoryFixture(nextDb).workout('new-profile');
      await nextDb
          .update(nextDb.setEntries)
          .write(const SetEntriesCompanion(weight: Value(300)));
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            return ref.watch(currentProfileProvider) == localProfileName
                ? db
                : nextDb;
          }),
        ],
      );
      final states = <AsyncValue<ExerciseHistory>>[];
      container.listen(
        provider,
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      final initial = await container.read(provider.future);
      expect(initial.sessions.single.sessionId, 'session');

      // Hold a real query's result after reading the old database.
      control.delay = true;
      await db
          .update(db.setEntries)
          .write(const SetEntriesCompanion(weight: Value(200)));
      await control.started.future.timeout(const Duration(seconds: 3));
      container
          .read(currentProfileProvider.notifier)
          .set('quadrille_user_other');
      expect(container.read(provider).isLoading, isTrue);
      final changed = await container.read(provider.future);
      expect(changed.sessions.single.sessionId, 'new-profile');
      expect(changed.stats.heaviestWeight, 300);
      final afterSwitch = states.length;

      control.release.complete();
      await control.returned.future;
      await db
          .update(db.setEntries)
          .write(const SetEntriesCompanion(weight: Value(900)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(provider).requireValue, same(changed));
      for (final state in states.skip(afterSwitch).where((s) => !s.isLoading)) {
        expect(state.requireValue.sessions.single.sessionId, 'new-profile');
      }
      final refreshed = Completer<ExerciseHistory>();
      final subscription = container.listen(provider, (_, next) {
        if (next.hasValue &&
            next.requireValue.stats.heaviestWeight == 350 &&
            !refreshed.isCompleted) {
          refreshed.complete(next.requireValue);
        }
      });
      await nextDb
          .update(nextDb.setEntries)
          .write(const SetEntriesCompanion(weight: Value(350)));
      expect(
        (await refreshed.future.timeout(
          const Duration(seconds: 3),
        )).stats.heaviestWeight,
        350,
      );
      subscription.close();
    },
  );
}
