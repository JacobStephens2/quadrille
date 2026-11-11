import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';
import 'package:quadrille/features/auth/data/profile_store.dart';
import 'package:quadrille/features/auth/data/token_store.dart';
import 'package:quadrille/features/backup/backup_providers.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/presentation/active_session_screen.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

class _Notifications implements NotificationService {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {}
}

/// Holds the start at the permission boundary, before the Rest timer is saved.
class _HeldPermission implements NotificationService {
  final entered = Completer<void>();
  final release = Completer<bool>();
  final scheduled = <String>[];

  @override
  Future<bool> ensurePermission() {
    if (!entered.isCompleted) entered.complete();
    return release.future;
  }

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    scheduled.add(body);
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {}
}

/// Holds alert submission so a later start stays queued and unsaved.
class _HeldSchedule implements NotificationService {
  Completer<void>? block;
  final blocked = Completer<void>();
  final scheduled = <String>[];

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    final gate = block;
    if (gate != null) {
      if (!blocked.isCompleted) blocked.complete();
      await gate.future;
    }
    scheduled.add(body);
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {}
}

class _Watch implements WatchService {
  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {}

  @override
  Future<void> clear() async {}
}

class _LocalAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}

class _MemoryTokens extends TokenStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}

  @override
  Future<void> clear() async {}
}

class _MemoryProfiles extends ProfileStore {
  @override
  Future<void> write(String profileName) async {}
}

typedef _Alert = ({DateTime endsAt, String title, String body});

/// One shared rest-alert slot. Cancel can be held so a test can see that the
/// guest profile is still current while the wipe drops the alert.
class _SlotNotifications implements NotificationService {
  Completer<void>? cancelGate;
  final cancelEntered = Completer<void>();
  _Alert? slot;
  int cancellations = 0;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    slot = (endsAt: endsAt, title: title, body: body);
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    final gate = cancelGate;
    if (gate != null) {
      if (!cancelEntered.isCompleted) cancelEntered.complete();
      await gate.future;
    }
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
    slot = null;
  }
}

class _RecordingWatch implements WatchService {
  final snapshots = <WatchSnapshot>[];
  int clears = 0;
  String? profileAtClear;
  String Function()? readProfile;

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {
    snapshots.add(snapshot);
  }

  @override
  Future<void> clear() async {
    clears++;
    profileAtClear = readProfile?.call();
  }
}

void main() {
  testWidgets('guest wipe hides the previous rest label from the next session', (
    tester,
  ) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final sessions = SessionRepository(db);
    final templates = TemplateRepository(db);

    final guestTemplate = await tester.runAsync(
      () => templates.createTemplate(name: 'Guest'),
    );
    await tester.runAsync(
      () => templates.addExercise(
        guestTemplate!,
        TemplateExerciseDraft(
          displayName: 'Previous Guest Exercise',
          orderLabel: '1',
        ),
      ),
    );
    final guestSession = await tester.runAsync(
      () => sessions.startFromTemplate(guestTemplate!),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        watchServiceProvider.overrideWithValue(_Watch()),
        authControllerProvider.overrideWith(_LocalAuth.new),
      ],
    );
    await tester.runAsync(() async {
      await container.read(authControllerProvider.future);
      await container
          .read(restTimerControllerProvider)
          .start(
            duration: const Duration(seconds: 90),
            sessionId: guestSession,
            sessionExerciseId: 'guest-exercise',
            label: 'Previous Guest Exercise',
          );
      await BackupService(db).wipeAllData();
    });
    container.dispose();

    final nextTemplate = await tester.runAsync(
      () => templates.createTemplate(name: 'Next'),
    );
    await tester.runAsync(
      () => templates.addExercise(
        nextTemplate!,
        TemplateExerciseDraft(
          displayName: 'Next User Exercise',
          orderLabel: '1',
        ),
      ),
    );
    final nextSession = await tester.runAsync(
      () => sessions.startFromTemplate(nextTemplate!),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(_Notifications()),
          watchServiceProvider.overrideWithValue(_Watch()),
          authControllerProvider.overrideWith(_LocalAuth.new),
          timerTickProvider.overrideWith((ref) => const Stream<int>.empty()),
        ],
        child: MaterialApp(home: ActiveSessionScreen(sessionId: nextSession!)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Previous Guest Exercise'), findsNothing);
    expect(find.text('Next User Exercise'), findsOneWidget);

    // Drift keeps a zero-duration timer after the last stream listener
    // leaves. Elapse it and close the database before the harness checks.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  });

  test('guest wipe drops a rest timer start that has not been saved', () async {
    final notifications = _HeldPermission();
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(notifications),
        watchServiceProvider.overrideWithValue(_Watch()),
        authControllerProvider.overrideWith(_LocalAuth.new),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    await container.read(authControllerProvider.future);
    final starting = container
        .read(restTimerControllerProvider)
        .start(
          duration: const Duration(seconds: 90),
          sessionId: 'guest-session',
          sessionExerciseId: 'guest-exercise',
          label: 'Previous Guest Exercise',
        );
    await notifications.entered.future;
    await BackupService(db).wipeAllData();
    notifications.release.complete(true);
    await starting;

    final saved = await (db.select(
      db.activeTimers,
    )..where((t) => t.id.equals('singleton'))).getSingleOrNull();
    expect(saved?.label, isNull);
    expect(notifications.scheduled, isEmpty);
  });

  test(
    'guest wipe drops a queued rest timer start that has not been saved',
    () async {
      final notifications = _HeldSchedule();
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(notifications),
          watchServiceProvider.overrideWithValue(_Watch()),
          authControllerProvider.overrideWith(_LocalAuth.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(authControllerProvider.future);
      final timer = container.read(restTimerControllerProvider);
      await timer.start(
        duration: const Duration(seconds: 30),
        label: 'Current',
      );
      final gate = Completer<void>();
      notifications.block = gate;
      final adjusting = timer.adjust(const Duration(seconds: 15));
      await notifications.blocked.future;
      final starting = timer.start(
        duration: const Duration(seconds: 90),
        label: 'Previous Guest Exercise',
      );
      await BackupService(db).wipeAllData();
      gate.complete();
      await Future.wait([adjusting, starting]);

      final saved = await (db.select(
        db.activeTimers,
      )..where((t) => t.id.equals('singleton'))).getSingleOrNull();
      expect(saved?.label, isNull);
      expect(
        notifications.scheduled,
        isNot(contains('Next: Previous Guest Exercise')),
      );
    },
  );

  test('a rest timer start after the guest wipe is saved', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        watchServiceProvider.overrideWithValue(_Watch()),
        authControllerProvider.overrideWith(_LocalAuth.new),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    await container.read(authControllerProvider.future);
    await BackupService(db).wipeAllData();
    await container
        .read(restTimerControllerProvider)
        .start(
          duration: const Duration(seconds: 45),
          label: 'Next User Exercise',
        );

    final saved = await (db.select(
      db.activeTimers,
    )..where((t) => t.id.equals('singleton'))).getSingleOrNull();
    expect(saved?.label, 'Next User Exercise');
  });

  test(
    'guest wipe cancels the rest alert and clears the watch before the account profile opens',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      const accountId = 'account-1';
      final accountProfile = userProfileName(accountId);
      final guest = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      final account = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      final databases = <String, QuadrilleDatabase>{
        localProfileName: guest,
        accountProfile: account,
      };
      final notifications = _SlotNotifications();
      final watch = _RecordingWatch();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith(
            (ref) => databases[ref.watch(currentProfileProvider)]!,
          ),
          notificationServiceProvider.overrideWithValue(notifications),
          watchServiceProvider.overrideWithValue(watch),
          tokenStoreProvider.overrideWithValue(_MemoryTokens()),
          profileStoreProvider.overrideWithValue(_MemoryProfiles()),
          adoptionBackupServiceProvider.overrideWith(
            (ref, profile) => BackupService(databases[profile]!),
          ),
          authApiProvider.overrideWithValue(
            AuthApi(
              baseUrl: 'https://example.com',
              client: MockClient((request) async {
                if (request.url.path == '/auth/me') {
                  return http.Response('{"detail":"no session"}', 401);
                }
                if (request.url.path == '/auth/login') {
                  return http.Response(
                    jsonEncode({
                      'user': {
                        'id': accountId,
                        'email': 'a@example.com',
                        'emailVerified': true,
                      },
                      'token': 'token-1',
                    }),
                    200,
                  );
                }
                return http.Response('{}', 200);
              }),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(guest.close);
      addTearDown(account.close);

      await container.read(authControllerProvider.future);
      watch.readProfile = () => container.read(currentProfileProvider);
      await container
          .read(restTimerControllerProvider)
          .start(
            duration: const Duration(seconds: 90),
            label: 'Previous Guest Exercise',
          );
      expect(notifications.slot?.body, 'Next: Previous Guest Exercise');
      expect(watch.snapshots.single.exerciseName, 'Previous Guest Exercise');

      notifications.cancelGate = Completer<void>();
      final loginDone = Completer<Object?>();
      unawaited(
        container
            .read(authControllerProvider.notifier)
            .login('a@example.com', 'secret')
            .then<void>(
              (_) {
                if (!loginDone.isCompleted) loginDone.complete(null);
              },
              onError: (Object error, StackTrace _) {
                if (!loginDone.isCompleted) loginDone.complete(error);
              },
            ),
      );

      final outcome = await Future.any<Object?>([
        notifications.cancelEntered.future.then<Object?>((_) => 'cancelled'),
        loginDone.future,
      ]).timeout(const Duration(seconds: 15));
      expect(
        outcome,
        'cancelled',
        reason:
            'sign-in ended before the guest rest alert was cancelled: $outcome',
      );
      expect(container.read(currentProfileProvider), localProfileName);

      notifications.cancelGate!.complete();
      final loginResult = await loginDone.future.timeout(
        const Duration(seconds: 15),
      );
      expect(loginResult, isNull);
      expect(notifications.slot, isNull);
      expect(notifications.cancellations, 1);
      expect(watch.clears, 1);
      expect(watch.profileAtClear, localProfileName);
      expect(container.read(currentProfileProvider), accountProfile);

      await container
          .read(restTimerControllerProvider)
          .start(
            duration: const Duration(seconds: 45),
            label: 'Next User Exercise',
          );
      expect(notifications.slot?.body, 'Next: Next User Exercise');
      expect(notifications.cancellations, 1);
      expect(watch.clears, 1);
      expect(watch.snapshots.last.exerciseName, 'Next User Exercise');
    },
  );
}
