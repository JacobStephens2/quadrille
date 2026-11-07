import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
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

const _accountA = AuthState(
  status: AuthStatus.signedIn,
  user: AuthUser(id: 'account-a', email: 'a@example.com', emailVerified: true),
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
  _PendingCall? scheduling;
  _PendingCall? permission;

  final scheduled = <_Alert>[];
  int cancellations = 0;

  @override
  Future<bool> ensurePermission() async {
    await permission?.wait();
    return true;
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
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
  }
}

class _Watch implements WatchService {
  final snapshots = <WatchSnapshot>[];
  int clears = 0;

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {
    snapshots.add(snapshot);
  }

  @override
  Future<void> clear() async {
    clears++;
  }
}

class _Push implements WebPushService {
  final scheduled = <_Alert>[];
  int cancellations = 0;

  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    scheduled.add((endsAt: endsAt, title: title, body: body));
  }

  @override
  Future<void> cancel({required String endpoint}) async {
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

class _DatabaseChoice extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final _databaseChoiceProvider = NotifierProvider<_DatabaseChoice, int>(
  _DatabaseChoice.new,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late QuadrilleDatabase profileA;
  late QuadrilleDatabase profileB;
  late ProviderContainer container;
  late RestTimerController timer;
  late _Notifications notifications;
  late _Watch watch;
  late _Push push;
  late _Auth auth;

  Future<ActiveTimer?> row(QuadrilleDatabase db) => (db.select(
    db.activeTimers,
  )..where((t) => t.id.equals('singleton'))).getSingleOrNull();

  setUp(() async {
    profileA = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    profileB = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final started = DateTime(2026, 11, 4, 12);
    await profileB
        .into(profileB.activeTimers)
        .insert(
          ActiveTimersCompanion.insert(
            id: const Value('singleton'),
            label: const Value('Other account'),
            startedAt: started,
            endsAt: started.add(const Duration(seconds: 30)),
            durationSeconds: 30,
            status: const Value(TimerStatus.running),
          ),
        );
    notifications = _Notifications();
    watch = _Watch();
    push = _Push();
    auth = _Auth(_accountA);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          final choice = ref.watch(_databaseChoiceProvider);
          return choice == 0 ? profileA : profileB;
        }),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(watch),
        webPushServiceProvider.overrideWithValue(push),
        authControllerProvider.overrideWith(() => auth),
      ],
    );
    timer = container.read(restTimerControllerProvider);
    await container.read(authControllerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await profileA.close();
    await profileB.close();
  });

  test(
    'a queued skip keeps the other profile timer and does not project alerts',
    () async {
      await timer.start(
        duration: const Duration(seconds: 60),
        label: 'Hidden Lift',
      );
      expect((await row(profileA))?.label, 'Hidden Lift');
      expect((await row(profileB))?.label, 'Other account');
      final gate = _PendingCall();
      notifications.scheduling = gate;
      final adjusting = timer.adjust(const Duration(seconds: 30));
      await gate.entered.future;
      notifications.scheduling = null;
      await pumpEventQueue();
      final skipping = timer.skip();

      final pushesAtSwitch = push.scheduled.length;
      final watchesAtSwitch = watch.snapshots.length;
      container.read(_databaseChoiceProvider.notifier).select(1);
      gate.completion.complete();
      await Future.wait([adjusting, skipping]);

      expect((await row(profileB))?.label, 'Other account');
      expect(push.scheduled, hasLength(pushesAtSwitch));
      expect(watch.snapshots, hasLength(watchesAtSwitch));
    },
  );

  test(
    'a stale publication does not cancel the other profile rest alert',
    () async {
      await timer.start(duration: const Duration(seconds: 60), label: 'A');
      final gate = notifications.scheduling = _PendingCall();
      final adjusting = timer.adjust(const Duration(seconds: 30));
      await gate.entered.future;
      notifications.scheduling = null;
      profileA.retireTimerGeneration();
      container.read(_databaseChoiceProvider.notifier).select(1);
      await timer.start(duration: const Duration(seconds: 45), label: 'B');
      final cancellationsAfterB = notifications.cancellations;
      gate.completion.complete();
      await adjusting;
      expect(notifications.cancellations, cancellationsAfterB);
    },
  );

  test(
    'a command on the current profile does not wait for the previous profile',
    () async {
      await timer.start(
        duration: const Duration(seconds: 60),
        label: 'Hidden Lift',
      );
      final gate = _PendingCall();
      notifications.scheduling = gate;
      final adjusting = timer.adjust(const Duration(seconds: 30));
      await gate.entered.future;
      notifications.scheduling = null;
      container.read(_databaseChoiceProvider.notifier).select(1);

      try {
        await timer
            .start(duration: const Duration(seconds: 45), label: 'B Lift')
            .timeout(const Duration(seconds: 1));
      } finally {
        if (!gate.completion.isCompleted) gate.completion.complete();
        await adjusting;
      }

      expect((await row(profileB))?.label, 'B Lift');
      expect((await row(profileA))?.label, 'Hidden Lift');
    },
  );

  test(
    'a start already waiting on permission still saves on the invoking profile',
    () async {
      final gate = _PendingCall();
      notifications.permission = gate;
      final starting = timer.start(
        duration: const Duration(seconds: 60),
        label: 'Hidden Lift',
      );
      await gate.entered.future;
      container.read(_databaseChoiceProvider.notifier).select(1);
      gate.completion.complete();
      await starting;

      expect((await row(profileA))?.label, 'Hidden Lift');
      expect((await row(profileB))?.label, 'Other account');
      expect(
        notifications.scheduled.map((alert) => alert.body),
        contains('Next: Hidden Lift'),
      );
    },
  );
}
