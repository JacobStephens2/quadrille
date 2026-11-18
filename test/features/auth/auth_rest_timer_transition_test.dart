import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quadrille/core/audio/rest_voice_player.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';
import 'package:quadrille/features/auth/data/profile_store.dart';
import 'package:quadrille/features/auth/data/token_store.dart';
import 'package:quadrille/features/backup/backup_providers.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/push/push_providers.dart';
import 'package:quadrille/features/push/web_push_service.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

typedef _Alert = ({DateTime endsAt, String title, String body});

class _Audio extends Mock implements AudioPlayer {}

class _PendingCall {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class _MemoryTokens extends TokenStore {
  _MemoryTokens({this.token});

  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}

class _MemoryProfiles extends ProfileStore {
  _MemoryProfiles({this.profile});

  String? profile;

  @override
  Future<String?> read() async => profile;

  @override
  Future<void> write(String profileName) async => profile = profileName;
}

class _Notifications implements NotificationService {
  _PendingCall? permission;
  _PendingCall? scheduling;
  _PendingCall? cancelling;
  _Alert? slot;
  final scheduled = <_Alert>[];
  int cancellations = 0;
  String? profileAtCancel;
  String Function()? readProfile;
  void Function(String)? recordEvent;

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
    bool voiceCuesEnabled = false,
  }) async {
    await scheduling?.wait();
    scheduled.add((endsAt: endsAt, title: title, body: body));
    slot = (endsAt: endsAt, title: title, body: body);
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    await cancelling?.wait();
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
    profileAtCancel = readProfile?.call();
    recordEvent?.call('notifications.cancel');
    slot = null;
  }
}

class _Watch implements WatchService {
  _PendingCall? updating;
  _PendingCall? clearing;
  final snapshots = <WatchSnapshot>[];
  int clears = 0;
  String? profileAtClear;
  String Function()? readProfile;
  void Function(String)? recordEvent;

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {
    await updating?.wait();
    snapshots.add(snapshot);
  }

  @override
  Future<void> clear() async {
    await clearing?.wait();
    clears++;
    profileAtClear = readProfile?.call();
    recordEvent?.call('watch.clear');
  }
}

class _Push implements WebPushService {
  _PendingCall? scheduling;
  _PendingCall? cancelling;
  final scheduled = <_Alert>[];
  int cancellations = 0;
  String? profileAtCancel;
  String? sessionAtCancel;
  String Function()? readProfile;
  String? Function()? readSession;
  void Function(String)? recordEvent;

  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    await scheduling?.wait();
    scheduled.add((endsAt: endsAt, title: title, body: body));
  }

  @override
  Future<void> cancel({required String endpoint}) async {
    await cancelling?.wait();
    cancellations++;
    profileAtCancel = readProfile?.call();
    sessionAtCancel = readSession?.call();
    recordEvent?.call('push.cancel');
  }
}

Map<String, dynamic> _user(String id, {bool verified = true}) => {
  'id': id,
  'email': '$id@example.com',
  'emailVerified': verified,
};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUpAll(() => registerFallbackValue(AssetSource('unused')));

  late Map<String, QuadrilleDatabase> databases;
  late _MemoryTokens tokens;
  late _MemoryProfiles profiles;
  late _Notifications notifications;
  late _Watch watch;
  late _Push push;
  late _Audio audio;
  late List<String> events;
  late String? activeSessionId;
  late Future<http.Response> Function(http.Request) authHandler;
  late ProviderContainer container;

  Future<ActiveTimer?> timerRow(String profile) => (databases[profile]!.select(
    databases[profile]!.activeTimers,
  )..where((t) => t.id.equals('singleton'))).getSingleOrNull();

  setUp(() async {
    databases = {
      localProfileName: QuadrilleDatabase.forTesting(NativeDatabase.memory()),
      userProfileName('a'): QuadrilleDatabase.forTesting(
        NativeDatabase.memory(),
      ),
      userProfileName('b'): QuadrilleDatabase.forTesting(
        NativeDatabase.memory(),
      ),
    };
    tokens = _MemoryTokens(token: 'token-a');
    profiles = _MemoryProfiles(profile: userProfileName('a'));
    notifications = _Notifications();
    watch = _Watch();
    push = _Push();
    audio = _Audio();
    events = [];
    activeSessionId = 'a';

    when(() => audio.play(any(), volume: any(named: 'volume'))).thenAnswer((
      _,
    ) async {
      events.add('audio.play');
    });
    when(audio.stop).thenAnswer((_) async {
      events.add('audio.stop');
    });
    when(audio.dispose).thenAnswer((_) async {});

    authHandler = (request) async {
      events.add('http:${request.url.path}');
      if (request.url.path == '/auth/me') {
        return activeSessionId == null
            ? http.Response('{"detail":"no session"}', 401)
            : http.Response(jsonEncode({'user': _user(activeSessionId!)}), 200);
      }
      if (request.url.path == '/auth/login' ||
          request.url.path == '/auth/register') {
        final id = (jsonDecode(request.body) as Map)['email'] as String;
        activeSessionId = id;
        return http.Response(
          jsonEncode({'user': _user(id), 'token': 'token-$id'}),
          200,
        );
      }
      if (request.url.path == '/auth/logout') {
        activeSessionId = null;
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{}', 200);
    };

    container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(tokens),
        profileStoreProvider.overrideWithValue(profiles),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(watch),
        webPushServiceProvider.overrideWithValue(push),
        restVoicePlayerProvider.overrideWith(
          (_) => RestVoicePlayer(createPlayer: () => audio),
        ),
        adoptionBackupServiceProvider.overrideWith(
          (ref, profile) => BackupService(databases[profile]!),
        ),
        databaseProvider.overrideWith(
          (ref) => databases[ref.watch(currentProfileProvider)]!,
        ),
        authApiProvider.overrideWithValue(
          AuthApi(
            baseUrl: 'https://example.com',
            client: MockClient((request) => authHandler(request)),
          ),
        ),
      ],
    );
    container.read(currentProfileProvider.notifier).set(userProfileName('a'));
    notifications.readProfile = () => container.read(currentProfileProvider);
    notifications.recordEvent = events.add;
    watch.readProfile = () => container.read(currentProfileProvider);
    watch.recordEvent = events.add;
    push.readProfile = () => container.read(currentProfileProvider);
    push.readSession = () => activeSessionId;
    push.recordEvent = events.add;
    await container.read(authControllerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    for (final db in databases.values) {
      await db.close();
    }
  });

  test(
    'logout dismisses voice, local notification, watch, and web push before revoking session or switching profiles while preserving rows and re-sign-in usability',
    () async {
      final timer = container.read(restTimerControllerProvider);
      await timer.start(
        duration: const Duration(seconds: 90),
        label: 'Private Lift',
      );
      expect(notifications.slot?.body, 'Next: Private Lift');
      expect(watch.snapshots.single.exerciseName, 'Private Lift');
      expect(push.scheduled.single.body, 'Next: Private Lift');

      events.clear();
      final cancelGate = notifications.cancelling = _PendingCall();
      final logoutOutcome = Completer<Object?>();
      unawaited(
        container
            .read(authControllerProvider.notifier)
            .logout()
            .then<void>(
              (_) {
                if (!logoutOutcome.isCompleted) logoutOutcome.complete(null);
              },
              onError: (Object error, StackTrace _) {
                if (!logoutOutcome.isCompleted) logoutOutcome.complete(error);
              },
            ),
      );

      final outcome = await Future.any<Object?>([
        cancelGate.entered.future.then<Object?>((_) => 'cancelled'),
        logoutOutcome.future,
      ]).timeout(const Duration(seconds: 5));
      expect(
        outcome,
        'cancelled',
        reason: 'logout finished before dismissing notifications: $outcome',
      );
      expect(events, ['audio.stop']);
      expect(container.read(currentProfileProvider), userProfileName('a'));
      expect(activeSessionId, 'a');

      notifications.cancelling = null;
      cancelGate.completion.complete();
      expect(await logoutOutcome.future.timeout(const Duration(seconds: 5)), isNull);

      expect(events, [
        'audio.stop',
        'notifications.cancel',
        'watch.clear',
        'push.cancel',
        'http:/auth/logout',
      ]);
      expect(notifications.slot, isNull);
      expect(notifications.cancellations, 1);
      expect(notifications.profileAtCancel, userProfileName('a'));
      expect(watch.clears, 1);
      expect(watch.profileAtClear, userProfileName('a'));
      expect(push.cancellations, 1);
      expect(push.profileAtCancel, userProfileName('a'));
      expect(push.sessionAtCancel, 'a');
      expect(container.read(currentProfileProvider), localProfileName);
      expect(container.read(authControllerProvider).value?.isSignedIn, isFalse);

      expect((await timerRow(userProfileName('a')))?.label, 'Private Lift');
      expect(await timerRow(localProfileName), isNull);

      await container
          .read(authControllerProvider.notifier)
          .login('a', 'password');
      expect(container.read(currentProfileProvider), userProfileName('a'));
      await timer.start(
        duration: const Duration(seconds: 45),
        label: 'Back Again',
      );
      expect((await timerRow(userProfileName('a')))?.label, 'Back Again');
      expect(notifications.slot?.body, 'Next: Back Again');
      expect(watch.snapshots.last.exerciseName, 'Back Again');
      expect(push.scheduled.last.body, 'Next: Back Again');
    },
  );

  for (final stage in ['permission', 'scheduling', 'watch', 'push']) {
    test(
      'logout does not wait on a stalled outgoing command at $stage and suppresses later stages and queued work',
      () async {
        final timer = container.read(restTimerControllerProvider);
        if (stage != 'permission') {
          await timer.start(
            duration: const Duration(seconds: 60),
            label: 'Initial Lift',
          );
        }
        final gate = _PendingCall();
        switch (stage) {
          case 'permission':
            notifications.permission = gate;
          case 'scheduling':
            notifications.scheduling = gate;
          case 'watch':
            watch.updating = gate;
          case 'push':
            push.scheduling = gate;
        }
        final pendingCommand = stage == 'permission'
            ? timer.start(duration: const Duration(seconds: 90), label: 'Stalled')
            : timer.adjust(const Duration(seconds: 30));
        await gate.entered.future;
        notifications.permission = null;
        notifications.scheduling = null;
        watch.updating = null;
        push.scheduling = null;
        final queued = timer.start(
          duration: const Duration(seconds: 30),
          label: 'Queued Stale Lift',
        );
        final notificationsBeforeLogout = notifications.scheduled.length;
        final watchesBeforeLogout = watch.snapshots.length;
        final pushesBeforeLogout = push.scheduled.length;

        try {
          await container
              .read(authControllerProvider.notifier)
              .logout()
              .timeout(const Duration(seconds: 2));
        } finally {
          gate.completion.complete();
        }
        await Future.wait([pendingCommand, queued]).timeout(
          const Duration(seconds: 5),
        );

        expect(container.read(currentProfileProvider), localProfileName);
        if (stage == 'permission') {
          expect(notifications.scheduled, hasLength(notificationsBeforeLogout));
        }
        if (stage == 'permission' || stage == 'scheduling') {
          expect(watch.snapshots, hasLength(watchesBeforeLogout));
        }
        if (stage != 'push') {
          expect(push.scheduled, hasLength(pushesBeforeLogout));
        }
        expect(
          notifications.scheduled.map((a) => a.body),
          isNot(contains('Next: Queued Stale Lift')),
        );
        expect(
          watch.snapshots.map((s) => s.exerciseName),
          isNot(contains('Queued Stale Lift')),
        );
        expect(
          push.scheduled.map((p) => p.body),
          isNot(contains('Next: Queued Stale Lift')),
        );
        expect(await timerRow(localProfileName), isNull);
        expect(
          (await timerRow(userProfileName('a')))?.label,
          isNot('Queued Stale Lift'),
        );
      },
    );
  }

  test(
    'timer start and adjust invoked while logout is dismissing alerts are suppressed',
    () async {
      final timer = container.read(restTimerControllerProvider);
      await timer.start(
        duration: const Duration(seconds: 90),
        label: 'First Lift',
      );
      final cancelGate = notifications.cancelling = _PendingCall();
      final logoutFuture = container
          .read(authControllerProvider.notifier)
          .logout();
      await cancelGate.entered.future;
      notifications.cancelling = null;

      final sneakedStart = timer.start(
        duration: const Duration(seconds: 30),
        label: 'Sneaked Start',
      );
      final sneakedAdjust = timer.adjust(const Duration(seconds: 15));

      cancelGate.completion.complete();
      await Future.wait([logoutFuture, sneakedStart, sneakedAdjust]);

      expect(container.read(currentProfileProvider), localProfileName);
      expect(notifications.slot, isNull);
      expect(
        watch.snapshots.map((s) => s.exerciseName),
        isNot(contains('Sneaked Start')),
      );
      expect(
        push.scheduled.map((s) => s.body),
        isNot(contains('Next: Sneaked Start')),
      );
      expect((await timerRow(userProfileName('a')))?.label, 'First Lift');
      expect((await timerRow(userProfileName('a')))?.durationSeconds, 90);
    },
  );

  for (final isRegister in [false, true]) {
    test(
      'non-guest ${isRegister ? 'register' : 'login'} dismisses outgoing alerts while session authorizes push, skips pending wait, preserves rows, and keeps re-sign-in usable',
      () async {
        final timer = container.read(restTimerControllerProvider);
        await timer.start(
          duration: const Duration(seconds: 90),
          label: 'Account A Lift',
        );
        final stalledGate = notifications.permission = _PendingCall();
        final stalledStart = timer.start(
          duration: const Duration(seconds: 45),
          label: 'Stalled A Lift',
        );
        await stalledGate.entered.future;
        notifications.permission = null;

        events.clear();
        final auth = container.read(authControllerProvider.notifier);
        try {
          await (isRegister
                  ? auth.register('b', 'password')
                  : auth.login('b', 'password'))
              .timeout(const Duration(seconds: 2));
        } finally {
          stalledGate.completion.complete();
        }
        await stalledStart.timeout(const Duration(seconds: 5));

        expect(events, [
          'audio.stop',
          'notifications.cancel',
          'watch.clear',
          'push.cancel',
          'http:${isRegister ? '/auth/register' : '/auth/login'}',
        ]);
        expect(notifications.slot, isNull);
        expect(notifications.cancellations, 1);
        expect(notifications.profileAtCancel, userProfileName('a'));
        expect(watch.clears, 1);
        expect(watch.profileAtClear, userProfileName('a'));
        expect(push.cancellations, 1);
        expect(push.profileAtCancel, userProfileName('a'));
        expect(push.sessionAtCancel, 'a');
        expect(container.read(currentProfileProvider), userProfileName('b'));
        expect((await timerRow(userProfileName('a')))?.label, 'Account A Lift');
        expect(await timerRow(userProfileName('b')), isNull);

        await timer.start(
          duration: const Duration(seconds: 60),
          label: 'Account B Lift',
        );
        expect((await timerRow(userProfileName('b')))?.label, 'Account B Lift');
        expect(notifications.slot?.body, 'Next: Account B Lift');

        await auth.login('a', 'password');
        expect(container.read(currentProfileProvider), userProfileName('a'));
        await timer.start(
          duration: const Duration(seconds: 75),
          label: 'Account A Again',
        );
        expect((await timerRow(userProfileName('a')))?.label, 'Account A Again');
        expect(notifications.slot?.body, 'Next: Account A Again');
      },
    );
  }

  test(
    'failed non-guest login releases transition hold so outgoing account timer remains usable',
    () async {
      final timer = container.read(restTimerControllerProvider);
      final defaultAuth = authHandler;
      authHandler = (request) async {
        if (request.url.path == '/auth/login') {
          return http.Response('{"detail":"Invalid email or password"}', 401);
        }
        return defaultAuth(request);
      };

      await expectLater(
        container.read(authControllerProvider.notifier).login('b', 'wrong'),
        throwsA(isA<AuthException>()),
      );
      expect(container.read(currentProfileProvider), userProfileName('a'));

      await timer.start(
        duration: const Duration(seconds: 60),
        label: 'Still Usable',
      );
      expect((await timerRow(userProfileName('a')))?.label, 'Still Usable');
      expect(notifications.slot?.body, 'Next: Still Usable');
    },
  );

  test(
    'session restore profile switch in AuthController.build dismisses outgoing local alerts without cancelling incoming push or deleting rows',
    () async {
      final timer = container.read(restTimerControllerProvider);
      await timer.start(
        duration: const Duration(seconds: 90),
        label: 'Account A Saved Lift',
      );
      expect(notifications.slot?.body, 'Next: Account A Saved Lift');

      activeSessionId = 'b';
      tokens.token = 'token-b';
      events.clear();
      container.invalidate(authControllerProvider);
      await container.read(authControllerProvider.future);

      expect(container.read(currentProfileProvider), userProfileName('b'));
      expect(events, [
        'http:/auth/me',
        'audio.stop',
        'notifications.cancel',
        'watch.clear',
      ]);
      expect(notifications.slot, isNull);
      expect(notifications.cancellations, 1);
      expect(notifications.profileAtCancel, userProfileName('a'));
      expect(watch.clears, 1);
      expect(watch.profileAtClear, userProfileName('a'));
      expect(push.cancellations, 0);
      expect(
        (await timerRow(userProfileName('a')))?.label,
        'Account A Saved Lift',
      );
    },
  );

  test(
    'same-account restoration in AuthController.build preserves active timer and alerts',
    () async {
      final timer = container.read(restTimerControllerProvider);
      await timer.start(
        duration: const Duration(seconds: 90),
        label: 'Account A Saved Lift',
      );
      events.clear();
      container.invalidate(authControllerProvider);
      await container.read(authControllerProvider.future);

      expect(container.read(currentProfileProvider), userProfileName('a'));
      expect(events, ['http:/auth/me']);
      expect(notifications.cancellations, 0);
      expect(watch.clears, 0);
      expect(push.cancellations, 0);
      expect(notifications.slot?.body, 'Next: Account A Saved Lift');
      expect(
        (await timerRow(userProfileName('a')))?.label,
        'Account A Saved Lift',
      );
    },
  );

  test(
    'guest-to-account restoration in AuthController.build dismisses local alerts without deleting or sealing guest rows',
    () async {
      await container.read(authControllerProvider.notifier).logout();
      expect(container.read(currentProfileProvider), localProfileName);

      final timer = container.read(restTimerControllerProvider);
      await timer.start(
        duration: const Duration(seconds: 90),
        label: 'Guest Saved Lift',
      );
      expect(notifications.slot?.body, 'Next: Guest Saved Lift');

      activeSessionId = 'a';
      tokens.token = 'token-a';
      events.clear();
      container.invalidate(authControllerProvider);
      await container.read(authControllerProvider.future);

      expect(container.read(currentProfileProvider), userProfileName('a'));
      expect(events, [
        'http:/auth/me',
        'audio.stop',
        'notifications.cancel',
        'watch.clear',
      ]);
      expect(notifications.slot, isNull);
      expect(
        (await timerRow(localProfileName))?.label,
        'Guest Saved Lift',
      );
      expect(databases[localProfileName]!.acceptsRestTimerWrites, isTrue);
    },
  );
}
