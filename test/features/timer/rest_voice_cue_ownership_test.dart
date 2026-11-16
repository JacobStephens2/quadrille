import 'dart:async';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        QueryExecutor,
        QueryInterceptor,
        Value,
        driftRuntimeOptions;
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
import 'package:quadrille/features/settings/settings_providers.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

import 'voice_audio_fixture.dart';

typedef _Alert = ({DateTime endsAt, String title, String body, bool voice});

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

class _SettingsSelectGate extends QueryInterceptor {
  _PendingCall? pending;
  int skip = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('app_settings') && pending != null) {
      if (skip > 0) {
        skip--;
      } else {
        final gate = pending!;
        pending = null;
        await gate.wait();
      }
    }
    return executor.runSelect(statement, args);
  }
}

class _SlotNotifications implements NotificationService {
  _Alert? slot;
  int schedules = 0;
  int cancellations = 0;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
    bool voiceCuesEnabled = false,
  }) async {
    schedules++;
    slot = (endsAt: endsAt, title: title, body: body, voice: voiceCuesEnabled);
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
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

Future<void> _insertRunningTimer(
  QuadrilleDatabase db, {
  required DateTime now,
  required String label,
}) {
  return db
      .into(db.activeTimers)
      .insert(
        ActiveTimersCompanion.insert(
          id: const Value('singleton'),
          label: Value(label),
          startedAt: now,
          endsAt: now.add(const Duration(seconds: 90)),
          durationSeconds: 90,
          status: const Value(TimerStatus.running),
        ),
      );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _SettingsSelectGate settingsGate;
  late QuadrilleDatabase profileA;
  late QuadrilleDatabase profileB;
  late ProviderContainer container;
  late RestTimerController timer;
  late _SlotNotifications notifications;
  late DateTime now;

  setUp(() async {
    now = DateTime(2026, 11, 16, 12);
    settingsGate = _SettingsSelectGate();
    profileA = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(settingsGate),
    );
    profileB = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    notifications = _SlotNotifications();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          final choice = ref.watch(_databaseChoiceProvider);
          return choice == 0 ? profileA : profileB;
        }),
        restTimerNowProvider.overrideWithValue(() => now),
        silentVoiceAudio,
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

  test(
    'stale refreshVoiceCues does not overwrite the new profile rest alert after profile switch',
    () async {
      await _insertRunningTimer(profileA, now: now, label: 'Private A Lift');
      final gate = settingsGate.pending = _PendingCall();
      final refreshing = timer.refreshVoiceCues();
      await gate.entered.future;

      container.read(_databaseChoiceProvider.notifier).select(1);
      await timer.start(
        duration: const Duration(seconds: 45),
        label: 'Profile B Lift',
      );
      expect(notifications.slot?.body, 'Next: Profile B Lift');

      gate.completion.complete();
      await refreshing;

      expect(notifications.slot?.body, 'Next: Profile B Lift');
    },
  );

  test(
    'stale refreshVoiceCues does not resurrect an alert after databaseProvider switches to an empty profile',
    () async {
      await _insertRunningTimer(profileA, now: now, label: 'Guest Exercise');
      container.listen(restVoiceCueUpdatesProvider, (_, _) {});
      await container.read(settingsProvider.future);

      final gate = settingsGate.pending = _PendingCall();
      final refreshing = timer.refreshVoiceCues();
      await gate.entered.future;

      container.read(_databaseChoiceProvider.notifier).select(1);
      await pumpEventQueue();
      expect(notifications.slot, isNull);

      gate.completion.complete();
      await refreshing;

      expect(notifications.slot, isNull);
    },
  );

  test(
    'refreshVoiceCues does not schedule or cancel once the guest profile is sealed',
    () async {
      await _insertRunningTimer(
        profileA,
        now: now,
        label: 'Guest Private Lift',
      );
      profileA.sealRestTimer();

      await timer.refreshVoiceCues();

      expect(notifications.slot, isNull);
      expect(notifications.schedules, 0);
      expect(notifications.cancellations, 0);
    },
  );

  test(
    'in-flight refreshVoiceCues does not schedule if the generation is retired during settings read',
    () async {
      await _insertRunningTimer(
        profileA,
        now: now,
        label: 'Guest Private Lift',
      );
      final gate = settingsGate.pending = _PendingCall();
      final refreshing = timer.refreshVoiceCues();
      await gate.entered.future;

      profileA.retireTimerGeneration();
      gate.completion.complete();
      await refreshing;

      expect(notifications.slot, isNull);
      expect(notifications.schedules, 0);
    },
  );

  test(
    'start does not overwrite another profile alert if its generation is retired during notification settings read',
    () async {
      settingsGate.skip = 1;
      final gate = settingsGate.pending = _PendingCall();
      final startingA = timer.start(
        duration: const Duration(seconds: 60),
        label: 'Guest Private Lift',
      );
      await gate.entered.future;

      profileA.retireTimerGeneration();
      container.read(_databaseChoiceProvider.notifier).select(1);
      await timer.start(
        duration: const Duration(seconds: 45),
        label: 'Profile B Lift',
      );
      expect(notifications.slot?.body, 'Next: Profile B Lift');

      gate.completion.complete();
      await startingA;

      expect(notifications.slot?.body, 'Next: Profile B Lift');
    },
  );
}
