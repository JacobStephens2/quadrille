import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/set_entry_controller.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';

import 'set_entry_fixture.dart';

class EntryWait {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class EntryDatabaseWaits extends QueryInterceptor {
  EntryWait? persistence;
  EntryWait? grid;
  bool fail = false;

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('set_entries')) {
      await persistence?.wait();
      if (fail) throw StateError('Disk full');
    }
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('workout_sessions')) await grid?.wait();
    return super.runSelect(executor, statement, args);
  }
}

class EntryOwnershipFixture {
  final databases = <QuadrilleDatabase>[];
  final waits = <EntryDatabaseWaits>[];
  final notifications = EntryNotifications();
  final watch = EntryWatch();
  late ProviderContainer container;
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  DateTime now = DateTime(2026);

  Future<QuadrilleDatabase> addDatabase() async {
    final interception = EntryDatabaseWaits();
    final db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interception),
    );
    databases.add(db);
    waits.add(interception);
    await db
        .into(db.workoutSessions)
        .insert(
          WorkoutSessionsCompanion.insert(
            id: 'session',
            name: 'Workout',
            startedAt: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.sessionExercises)
        .insert(
          SessionExercisesCompanion.insert(
            id: 'exercise',
            sessionId: 'session',
            displayName: 'Plank',
            orderLabel: '1',
            sortIndex: 0,
            createdAt: now,
            updatedAt: now,
            plannedSets: const Value(2),
            plannedRestSeconds: const Value(30),
            loadKind: const Value(LoadKind.timeOnly),
            durationMinSeconds: const Value(2),
          ),
        );
    for (var n = 1; n <= 2; n++) {
      await db
          .into(db.setEntries)
          .insert(
            SetEntriesCompanion.insert(
              id: 'set-$n',
              sessionExerciseId: 'exercise',
              setNumber: n,
              weight: const Value(70),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await db
        .into(db.activeTimers)
        .insert(
          ActiveTimersCompanion.insert(
            id: const Value('singleton'),
            label: const Value('Existing rest'),
            startedAt: now,
            endsAt: now.add(const Duration(minutes: 5)),
            durationSeconds: 300,
          ),
        );
    return db;
  }

  Future<void> open() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    a = await addDatabase();
    b = await addDatabase();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith(
          (ref) => ref.watch(currentProfileProvider) == 'b' ? b : a,
        ),
        setEntryNowProvider.overrideWithValue(() => now),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(watch),
        authControllerProvider.overrideWith(_EntryAuth.new),
      ],
    );
  }

  void switchTo(String profile) =>
      container.read(currentProfileProvider.notifier).set(profile);

  Future<SessionGridRow> row(QuadrilleDatabase db) async =>
      (await SessionRepository(db).readGrid('session')).single;

  SetEntrySeed seed(SessionGridRow row, {int index = 0}) =>
      SetEntrySeed.open(container, row: row, set: row.sets[index]);

  Future<ActiveTimer?> timer(QuadrilleDatabase db) =>
      db.select(db.activeTimers).getSingleOrNull();

  Future<void> close() async {
    container.dispose();
    for (final db in databases) {
      await db.close();
    }
  }
}

class _EntryAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}
