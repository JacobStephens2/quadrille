import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
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

/// One shared rest-alert slot, matching the platform adapters: the schedule
/// or cancel that finishes last is the one the current profile observes.
class _SlotNotifications implements NotificationService {
  _PendingCall? scheduling;
  _PendingCall? cancelling;
  _Alert? slot;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    await scheduling?.wait();
    slot = (endsAt: endsAt, title: title, body: body);
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    await cancelling?.wait();
    if (stillOwned != null && !stillOwned()) return;
    slot = null;
  }
}

class _Watch implements WatchService {
  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {}

  @override
  Future<void> clear() async {}
}

class _Push implements WebPushService {
  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancel({required String endpoint}) async {}
}

class _Auth extends AuthController {
  @override
  Future<AuthState> build() async => _accountA;
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
  late _SlotNotifications notifications;

  setUp(() async {
    profileA = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    profileB = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    notifications = _SlotNotifications();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          final choice = ref.watch(_databaseChoiceProvider);
          return choice == 0 ? profileA : profileB;
        }),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(_Watch()),
        webPushServiceProvider.overrideWithValue(_Push()),
        authControllerProvider.overrideWith(_Auth.new),
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

  test('a stale cancel does not clear the other profile rest alert', () async {
    await timer.start(duration: const Duration(seconds: 60), label: 'A');
    final scheduleGate = notifications.scheduling = _PendingCall();
    final adjusting = timer.adjust(const Duration(seconds: 30));
    await scheduleGate.entered.future;
    notifications.scheduling = null;
    final cancelGate = notifications.cancelling = _PendingCall();
    profileA.retireTimerGeneration();
    scheduleGate.completion.complete();
    await pumpEventQueue();
    final cancelInFlight = cancelGate.entered.isCompleted;
    container.read(_databaseChoiceProvider.notifier).select(1);
    await timer.start(duration: const Duration(seconds: 45), label: 'B');
    if (cancelInFlight) cancelGate.completion.complete();
    await adjusting;
    expect(
      notifications.slot?.body,
      'Next: B',
      reason: 'cancelInFlight=$cancelInFlight',
    );
  });
}
