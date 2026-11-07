import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, TransactionExecutor;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';
import 'package:quadrille/features/push/push_providers.dart';
import 'package:quadrille/features/push/web_push_service.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

typedef _Alert = ({DateTime endsAt, String title, String body});

const _verifiedAccount = AuthState(
  status: AuthStatus.signedIn,
  user: AuthUser(id: 'user', email: 'test@example.com', emailVerified: true),
);

class _PendingCall {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class _Notifications implements NotificationService {
  Completer<bool>? permission;
  final permissionEntered = Completer<void>();
  bool permissionGranted = true;
  Object? permissionFailure;
  _PendingCall? scheduling;
  _PendingCall? cancelling;
  final scheduled = <_Alert>[];
  int cancellations = 0;

  @override
  Future<bool> ensurePermission() async {
    if (!permissionEntered.isCompleted) permissionEntered.complete();
    if (permissionFailure != null) throw permissionFailure!;
    return await permission?.future ?? permissionGranted;
  }

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    await scheduling?.wait();
    scheduled.add((endsAt: endsAt, title: title, body: body));
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    await cancelling?.wait();
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
  }
}

class _Watch implements WatchService {
  final snapshots = <WatchSnapshot>[];
  _PendingCall? updating;
  _PendingCall? clearing;
  int clears = 0;

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {
    await updating?.wait();
    snapshots.add(snapshot);
  }

  @override
  Future<void> clear() async {
    await clearing?.wait();
    clears++;
  }
}

class _Push implements WebPushService {
  _PendingCall? scheduling;
  _PendingCall? cancelling;
  final scheduled = <_Alert>[];
  final endpoints = <String>[];
  int cancellations = 0;

  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    await scheduling?.wait();
    endpoints.add(endpoint);
    scheduled.add((endsAt: endsAt, title: title, body: body));
  }

  @override
  Future<void> cancel({required String endpoint}) async {
    await cancelling?.wait();
    endpoints.add(endpoint);
    cancellations++;
  }
}

class _Auth extends AuthController {
  _Auth(this.initial);
  final AuthState initial;

  @override
  Future<AuthState> build() async => initial;

  void change(AuthState next) => state = AsyncData(next);
}

class _PersistenceControl extends QueryInterceptor {
  Object? insertFailure;
  Object? readBackFailure;
  Completer<void>? stallNextActiveTimerUpdate;
  final updateEntered = Completer<void>();

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('active_timers') &&
        stallNextActiveTimerUpdate != null) {
      if (!updateEntered.isCompleted) updateEntered.complete();
      await stallNextActiveTimerUpdate!.future;
      stallNextActiveTimerUpdate = null;
    }
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('active_timers') && insertFailure != null) {
      return Future.error(insertFailure!);
    }
    return executor.runInsert(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (executor is TransactionExecutor && readBackFailure != null) {
      return Future.error(readBackFailure!);
    }
    return executor.runSelect(statement, args);
  }
}

void main() {
  late QuadrilleDatabase db;
  late ProviderContainer container;
  late RestTimerController timer;
  late _Watch watch;
  late _Notifications notifications;
  late _Push push;
  late _PersistenceControl persistence;
  late DateTime now;
  late _Auth auth;

  Future<ActiveTimer?> saved() => container.refresh(activeTimerProvider.future);

  setUp(() async {
    persistence = _PersistenceControl();
    db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(persistence),
    );
    now = DateTime(2026, 11, 4, 12, 0, 0, 789);
    watch = _Watch();
    notifications = _Notifications();
    push = _Push();
    auth = _Auth(AuthState.localOnly);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        restTimerNowProvider.overrideWithValue(() => now),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(watch),
        webPushServiceProvider.overrideWithValue(push),
        authControllerProvider.overrideWith(() => auth),
      ],
    );
    timer = container.read(restTimerControllerProvider);
    container.listen(activeTimerProvider, (_, _) {});
    await container.read(authControllerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('adjust refreshes the watch from the saved timer', () async {
    await timer.start(duration: const Duration(seconds: 60), label: 'Bench');
    await timer.adjust(const Duration(seconds: 30));

    final saved = await container.refresh(activeTimerProvider.future);
    expect(watch.snapshots, hasLength(2));
    expect(watch.snapshots.last.exerciseName, 'Bench');
    expect(
      watch.snapshots.last.restEndsAtMillis,
      saved!.endsAt.millisecondsSinceEpoch,
    );
  });

  test('skip after a permission-blocked start leaves no timer', () async {
    notifications.permission = Completer<bool>();
    final starting = timer.start(duration: const Duration(seconds: 60));
    await notifications.permissionEntered.future;
    final skipping = timer.skip();
    await container.refresh(activeTimerProvider.future);
    notifications.permission!.complete(true);
    await Future.wait([starting, skipping]);

    expect(await container.refresh(activeTimerProvider.future), isNull);
  });

  test('start and adjust project one complete committed snapshot', () async {
    auth.change(_verifiedAccount);
    await timer.start(
      duration: const Duration(seconds: 60),
      sessionId: 'session',
      sessionExerciseId: 'exercise',
      label: '1A · Bench (Set 2)',
    );
    final first = (await saved())!;
    expect(first.startedAt, DateTime(2026, 11, 4, 12));
    expect(first.endsAt, DateTime(2026, 11, 4, 12, 1));
    expect(first.durationSeconds, 60);
    expect(first.status, TimerStatus.running);

    await timer.adjust(const Duration(seconds: 30));
    final adjusted = (await saved())!;
    expect(adjusted.sessionId, 'session');
    expect(adjusted.sessionExerciseId, 'exercise');
    expect(adjusted.label, first.label);
    expect(adjusted.startedAt, first.startedAt);
    expect(adjusted.durationSeconds, 90);
    expect(adjusted.endsAt, DateTime(2026, 11, 4, 12, 1, 30));
    expect(adjusted.status, TimerStatus.running);
    expect(notifications.scheduled, [
      (
        endsAt: first.endsAt,
        title: 'Rest complete',
        body: 'Next: ${first.label}',
      ),
      (
        endsAt: adjusted.endsAt,
        title: 'Rest complete',
        body: 'Next: ${first.label}',
      ),
    ]);
    expect(push.scheduled, notifications.scheduled);
    expect(push.endpoints, [accountApiBaseUrl, accountApiBaseUrl]);
    expect(watch.snapshots.map((s) => s.restEndsAtMillis), [
      first.endsAt.millisecondsSinceEpoch,
      adjusted.endsAt.millisecondsSinceEpoch,
    ]);
    expect(watch.snapshots.map((s) => s.exerciseName), [
      first.label,
      first.label,
    ]);
  });

  test('nonpositive starts leave the singleton and alerts unchanged', () async {
    await timer.start(duration: const Duration(seconds: 60), label: 'A');
    final original = await saved();
    await timer.start(duration: Duration.zero, label: 'B');
    await timer.start(duration: const Duration(seconds: -1), label: 'C');
    expect(await saved(), original);
    expect(notifications.scheduled, hasLength(1));
    expect(watch.snapshots, hasLength(1));
  });

  test(
    'start replaces the singleton and clears previous optional metadata',
    () async {
      await timer.start(
        duration: const Duration(seconds: 60),
        sessionId: 'old-session',
        sessionExerciseId: 'old-exercise',
        label: 'A',
      );
      now = now.add(const Duration(seconds: 10));
      await timer.start(duration: const Duration(seconds: 90));
      final replacement = (await saved())!;
      expect(replacement.id, 'singleton');
      expect(replacement.sessionId, isNull);
      expect(replacement.sessionExerciseId, isNull);
      expect(replacement.label, isNull);
      expect(replacement.durationSeconds, 90);
      expect(replacement.endsAt, DateTime(2026, 11, 4, 12, 1, 40));
      expect(notifications.scheduled.last.body, 'Time for your next set.');
      expect(watch.snapshots.last.exerciseName, 'Rest');
    },
  );

  test('elapsed deadlines remain available until dismissed', () async {
    await timer.start(duration: const Duration(seconds: 60), label: 'A');
    now = now.add(const Duration(minutes: 2));
    expect((await saved())!.endsAt, DateTime(2026, 11, 4, 12, 1));
    await timer.adjust(const Duration(seconds: -9999));
    final clamped = (await saved())!;
    expect(clamped.endsAt, DateTime(2026, 11, 4, 12, 2));
    expect(clamped.durationSeconds, 120);
    expect(clamped.label, 'A');
    await timer.skip();
    expect(await saved(), isNull);
  });

  test('adjust without a timer does nothing', () async {
    await timer.adjust(const Duration(seconds: 30));
    expect(await saved(), isNull);
    expect(notifications.scheduled, isEmpty);
    expect(watch.snapshots, isEmpty);
    expect(push.scheduled, isEmpty);
  });

  test(
    'overlapping adjustments accumulate while scheduling is pending',
    () async {
      await timer.start(duration: const Duration(seconds: 60));
      final pending = notifications.scheduling = _PendingCall();
      final first = timer.adjust(const Duration(seconds: 30));
      await pending.entered.future;
      final second = timer.adjust(const Duration(seconds: 30));
      expect((await saved())!.endsAt, DateTime(2026, 11, 4, 12, 1, 30));
      pending.completion.complete();
      await Future.wait([first, second]);
      expect((await saved())!.endsAt, DateTime(2026, 11, 4, 12, 2));
      expect(notifications.scheduled.map((a) => a.endsAt), [
        DateTime(2026, 11, 4, 12, 1),
        DateTime(2026, 11, 4, 12, 1, 30),
        DateTime(2026, 11, 4, 12, 2),
      ]);
    },
  );

  test(
    'replacement during adjustment keeps labels and deadlines together',
    () async {
      await timer.start(duration: const Duration(seconds: 60), label: 'A');
      final pending = notifications.scheduling = _PendingCall();
      final adjusting = timer.adjust(const Duration(seconds: 30));
      await pending.entered.future;
      final replacing = timer.start(
        duration: const Duration(seconds: 120),
        label: 'B',
      );
      expect((await saved())!.label, 'A');
      pending.completion.complete();
      await Future.wait([adjusting, replacing]);
      expect(notifications.scheduled.map((a) => (a.body, a.endsAt)), [
        ('Next: A', DateTime(2026, 11, 4, 12, 1)),
        ('Next: A', DateTime(2026, 11, 4, 12, 1, 30)),
        ('Next: B', DateTime(2026, 11, 4, 12, 2)),
      ]);
      expect(watch.snapshots.map((s) => s.exerciseName), ['A', 'A', 'B']);
      expect((await saved())!.label, 'B');
    },
  );

  test(
    'a retired timer generation cancels the scheduled rest alert and skips the watch',
    () async {
      auth.change(_verifiedAccount);
      final pending = notifications.scheduling = _PendingCall();
      final starting = timer.start(
        duration: const Duration(seconds: 60),
        label: 'Bench',
      );
      await pending.entered.future;
      db.retireTimerGeneration();
      pending.completion.complete();
      await starting;

      expect(notifications.scheduled, hasLength(1));
      expect(notifications.scheduled.single, (
        endsAt: DateTime(2026, 11, 4, 12, 1),
        title: 'Rest complete',
        body: 'Next: Bench',
      ));
      expect(notifications.cancellations, 1);
      expect(watch.snapshots, isEmpty);
      expect(push.scheduled, isEmpty);
    },
  );

  for (final lengthening in [true, false]) {
    test(
      '${lengthening ? 'lengthening' : 'shortening'} cancels its rest alert and skips the watch when the generation is retired',
      () async {
        auth.change(_verifiedAccount);
        await timer.start(
          duration: const Duration(seconds: 60),
          label: 'Bench',
        );
        final pending = notifications.scheduling = _PendingCall();
        final adjusting = timer.adjust(
          Duration(seconds: lengthening ? 30 : -15),
        );
        await pending.entered.future;
        final watches = watch.snapshots.length;
        final pushes = push.scheduled.length;
        db.retireTimerGeneration();
        pending.completion.complete();
        await adjusting;

        expect(notifications.cancellations, 1);
        expect(watch.snapshots, hasLength(watches));
        expect(watch.snapshots.single.exerciseName, 'Bench');
        expect(
          watch.snapshots.single.restEndsAtMillis,
          DateTime(2026, 11, 4, 12, 1).millisecondsSinceEpoch,
        );
        expect(push.scheduled, hasLength(pushes));
        expect(notifications.scheduled.last, (
          endsAt: lengthening
              ? DateTime(2026, 11, 4, 12, 1, 30)
              : DateTime(2026, 11, 4, 12, 0, 45),
          title: 'Rest complete',
          body: 'Next: Bench',
        ));
      },
    );
  }

  test(
    'adjust retired mid-write still leaves the alert on the saved deadline',
    () async {
      await timer.start(duration: const Duration(seconds: 60), label: 'Bench');
      persistence.stallNextActiveTimerUpdate = Completer<void>();
      final adjusting = timer.adjust(const Duration(seconds: 30));
      await persistence.updateEntered.future;
      db.retireTimerGeneration();
      persistence.stallNextActiveTimerUpdate!.complete();
      await adjusting;

      final row = await saved();
      expect(row, isNotNull);
      expect(notifications.scheduled.last.endsAt, row!.endsAt);
    },
  );

  test('skip waits for pending scheduling before cancellation', () async {
    final pending = notifications.scheduling = _PendingCall();
    var started = false;
    final starting = timer
        .start(duration: const Duration(seconds: 60))
        .then((_) => started = true);
    await pending.entered.future;
    final skipping = timer.skip();
    expect(await saved(), isNotNull);
    expect(started, isFalse);
    expect(notifications.cancellations, 0);
    pending.completion.complete();
    await Future.wait([starting, skipping]);
    expect(notifications.scheduled, hasLength(1));
    expect(notifications.cancellations, 1);
    expect(watch.clears, 1);
    expect(await saved(), isNull);
  });

  test(
    'start waits for pending cancellation before scheduling again',
    () async {
      await timer.start(duration: const Duration(seconds: 60));
      final pending = notifications.cancelling = _PendingCall();
      var skipped = false;
      final skipping = timer.skip().then((_) => skipped = true);
      await pending.entered.future;
      final starting = timer.start(
        duration: const Duration(seconds: 90),
        label: 'B',
      );
      expect(await saved(), isNull);
      expect(skipped, isFalse);
      expect(notifications.scheduled, hasLength(1));
      pending.completion.complete();
      await Future.wait([skipping, starting]);
      expect((await saved())!.label, 'B');
      expect(notifications.scheduled, hasLength(2));
    },
  );

  test(
    'permission denial schedules; an exception preserves the previous timer',
    () async {
      notifications.permissionGranted = false;
      await timer.start(duration: const Duration(seconds: 60));
      final original = await saved();
      expect(notifications.scheduled, hasLength(1));
      final failure = StateError('permission failed');
      notifications.permissionFailure = failure;
      await expectLater(
        timer.start(duration: const Duration(seconds: 90)),
        throwsA(same(failure)),
      );
      expect(await saved(), original);
      expect(notifications.scheduled, hasLength(1));
      await timer.skip();
      expect(await saved(), isNull);
    },
  );

  for (final readBack in [false, true]) {
    test(
      '${readBack ? 'read-back' : 'write'} failure publishes no alerts and releases the queue',
      () async {
        final failure = StateError('persistence failed');
        if (readBack) {
          persistence.readBackFailure = failure;
        } else {
          persistence.insertFailure = failure;
        }
        final failing = expectLater(
          timer.start(duration: const Duration(seconds: 60)),
          throwsA(same(failure)),
        );
        final skipping = timer.skip();
        await Future.wait([failing, skipping]);
        expect(await saved(), isNull);
        expect(notifications.scheduled, isEmpty);
        expect(watch.snapshots, isEmpty);
        expect(push.scheduled, isEmpty);
        persistence.insertFailure = null;
        persistence.readBackFailure = null;
        await timer.start(duration: const Duration(seconds: 90));
        expect((await saved())!.durationSeconds, 90);
      },
    );
  }

  test('alert failure retains the commit and releases a queued skip', () async {
    final pending = notifications.scheduling = _PendingCall();
    final failure = StateError('schedule failed');
    final failing = expectLater(
      timer.start(duration: const Duration(seconds: 60)),
      throwsA(same(failure)),
    );
    await pending.entered.future;
    expect((await saved())!.durationSeconds, 60);
    final skipping = timer.skip();
    pending.completion.completeError(failure);
    await Future.wait([failing, skipping]);
    expect(watch.snapshots, isEmpty);
    expect(push.scheduled, isEmpty);
    expect(await saved(), isNull);
    notifications.scheduling = null;
    await timer.start(duration: const Duration(seconds: 90));
    expect((await saved())!.durationSeconds, 90);
  });

  test(
    'failed transactional read-back retains the previous singleton',
    () async {
      await timer.start(duration: const Duration(seconds: 60), label: 'A');
      final original = await saved();
      final failure = StateError('read-back failed');
      persistence.readBackFailure = failure;
      await expectLater(
        timer.start(duration: const Duration(seconds: 90), label: 'B'),
        throwsA(same(failure)),
      );
      expect(await saved(), original);
      expect(notifications.scheduled, hasLength(1));
      expect(watch.snapshots, hasLength(1));
    },
  );

  for (final verified in [false, true]) {
    test(
      'push eligibility follows verified account status ($verified)',
      () async {
        auth.change(
          AuthState(
            status: AuthStatus.signedIn,
            user: AuthUser(
              id: 'user',
              email: 'test@example.com',
              emailVerified: verified,
            ),
          ),
        );
        await timer.start(duration: const Duration(seconds: 60));
        await timer.adjust(const Duration(seconds: 30));
        await timer.skip();
        expect(push.scheduled, hasLength(verified ? 2 : 0));
        expect(push.cancellations, verified ? 1 : 0);
        expect(notifications.cancellations, 1);
        expect(watch.clears, 1);
        await timer.skip();
        expect(push.cancellations, verified ? 2 : 0);
        expect(notifications.cancellations, 2);
        expect(watch.clears, 2);
      },
    );
  }

  for (final watchEdge in [true, false]) {
    test(
      'skip awaits pending ${watchEdge ? 'watch' : 'push'} scheduling',
      () async {
        auth.change(_verifiedAccount);
        final pending = _PendingCall();
        if (watchEdge) {
          watch.updating = pending;
        } else {
          push.scheduling = pending;
        }
        var complete = false;
        final starting = timer
            .start(duration: const Duration(seconds: 60))
            .then((_) => complete = true);
        await pending.entered.future;
        final skipping = timer.skip();
        expect(await saved(), isNotNull);
        expect(complete, isFalse);
        expect(notifications.cancellations, 0);
        pending.completion.complete();
        await Future.wait([starting, skipping]);
        expect(await saved(), isNull);
        expect(push.scheduled, hasLength(1));
        expect(push.cancellations, 1);
        expect(watch.snapshots, hasLength(1));
        expect(watch.clears, 1);
      },
    );

    test(
      'start awaits pending ${watchEdge ? 'watch' : 'push'} cancellation',
      () async {
        auth.change(_verifiedAccount);
        final pending = _PendingCall();
        if (watchEdge) {
          watch.clearing = pending;
        } else {
          push.cancelling = pending;
        }
        var complete = false;
        final skipping = timer.skip().then((_) => complete = true);
        await pending.entered.future;
        final starting = timer.start(duration: const Duration(seconds: 60));
        expect(await saved(), isNull);
        expect(complete, isFalse);
        expect(notifications.scheduled, isEmpty);
        pending.completion.complete();
        await Future.wait([skipping, starting]);
        expect(await saved(), isNotNull);
        expect(push.cancellations, 1);
        expect(push.scheduled, hasLength(1));
      },
    );

    test(
      '${watchEdge ? 'watch' : 'push'} error fails its command and releases the queue',
      () async {
        auth.change(_verifiedAccount);
        final pending = _PendingCall();
        if (watchEdge) {
          watch.updating = pending;
        } else {
          push.scheduling = pending;
        }
        final failure = StateError('adapter failed');
        final failing = expectLater(
          timer.start(duration: const Duration(seconds: 60)),
          throwsA(same(failure)),
        );
        await pending.entered.future;
        expect(await saved(), isNotNull);
        final skipping = timer.skip();
        pending.completion.completeError(failure);
        await Future.wait([failing, skipping]);
        expect(await saved(), isNull);
        expect(push.cancellations, 1);
        expect(push.scheduled, isEmpty);
      },
    );
  }
}
