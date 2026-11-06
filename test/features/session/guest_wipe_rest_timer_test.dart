import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
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
  Future<void> cancel() async {}
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
  Future<void> cancel() async {}
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
  Future<void> cancel() async {}
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
}
