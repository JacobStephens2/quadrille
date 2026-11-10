import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

class EndingWait {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class EndingDatabaseWaits extends QueryInterceptor {
  EndingWait? selecting;
  EndingWait? updating;
  EndingWait? committing;
  bool failMutation = false;
  bool failSets = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('workout_sessions')) await selecting?.wait();
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('workout_sessions')) {
      await updating?.wait();
      if (failMutation) throw StateError('Disk full');
    }
    if (failSets && statement.contains('set_entries')) {
      throw StateError('Set write failed');
    }
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    await committing?.wait();
    await super.commitTransaction(inner);
  }
}

class EndingNotifications implements NotificationService {
  EndingWait? cancelling;
  bool fail = false;
  int cancellations = 0;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
    await cancelling?.wait();
    if (fail) throw StateError('Alerts could not be cancelled');
  }
}

class EndingWatch implements WatchService {
  int clears = 0;

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {}

  @override
  Future<void> clear() async => clears++;
}

class EndingAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;

  void change(AuthState next) => state = AsyncData(next);
}

class _SyncContext extends Notifier<AuthSyncContext?> {
  @override
  AuthSyncContext? build() => null;

  void set(AuthSyncContext? context) => state = context;
}

final _syncContextProvider = NotifierProvider<_SyncContext, AuthSyncContext?>(
  _SyncContext.new,
);

class EndingFixture {
  static const sessionId = 'workout';
  final databases = <QuadrilleDatabase>[];
  final waits = <EndingDatabaseWaits>[];
  final notifications = EndingNotifications();
  final watch = EndingWatch();
  final auth = EndingAuth();
  final requests = <http.Request>[];
  late ProviderContainer container;
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  Future<http.Response> Function(http.Request)? transport;

  Future<QuadrilleDatabase> addDatabase({bool withGrid = true}) async {
    final interception = EndingDatabaseWaits();
    final db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interception),
    );
    databases.add(db);
    waits.add(interception);
    final now = DateTime(2026, 11, 4, 12);
    await db
        .into(db.workoutSessions)
        .insert(
          WorkoutSessionsCompanion.insert(
            id: sessionId,
            name: 'Push A',
            startedAt: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (withGrid) {
      await db
          .into(db.sessionExercises)
          .insert(
            SessionExercisesCompanion.insert(
              id: 'exercise',
              sessionId: sessionId,
              displayName: 'Press',
              orderLabel: '1',
              sortIndex: 0,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.setEntries)
          .insert(
            SetEntriesCompanion.insert(
              id: 'set',
              sessionExerciseId: 'exercise',
              setNumber: 1,
              status: const Value(SetStatus.completed),
              weight: const Value(70),
              reps: const Value(10),
              completedAt: Value(now),
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
            sessionId: const Value('different-workout'),
            label: const Value('Other rest context'),
            startedAt: now,
            endsAt: now.add(const Duration(seconds: 60)),
            durationSeconds: 60,
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
          (ref) =>
              ref.watch(currentProfileProvider) == userProfileName('b') ? b : a,
        ),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(watch),
        authControllerProvider.overrideWith(() => auth),
        authSyncContextProvider.overrideWith(
          (ref) => ref.watch(_syncContextProvider),
        ),
        authApiProvider.overrideWithValue(
          AuthApi(
            baseUrl: 'https://account.test',
            client: MockClient((request) async {
              requests.add(request);
              return transport == null
                  ? http.Response(jsonEncode({'revision': 1}), 200)
                  : transport!(request);
            }),
          ),
        ),
      ],
    );
    container.read(currentProfileProvider.notifier).set(userProfileName('a'));
    await container.read(authControllerProvider.future);
  }

  void changeSync({String account = 'a', bool eligible = true}) => container
      .read(_syncContextProvider.notifier)
      .set(
        eligible
            ? AuthSyncContext(
                accountId: account,
                profileName: userProfileName(account),
                bearer: 'token-$account',
                generation: Object(),
              )
            : null,
      );

  void switchTo(String account) => container
      .read(currentProfileProvider.notifier)
      .set(userProfileName(account));

  SessionRepository sessions(QuadrilleDatabase db) => SessionRepository(db);

  Future<WorkoutSession> session(QuadrilleDatabase db) async =>
      (await sessions(db).watchSession(sessionId).first)!;

  Future<ActiveTimer?> timer(QuadrilleDatabase db) =>
      db.select(db.activeTimers).getSingleOrNull();

  Future<void> close() async {
    container.dispose();
    for (final db in databases) {
      await db.close();
    }
  }
}
