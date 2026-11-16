import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';
import 'package:quadrille/features/settings/presentation/settings_screen.dart';
import 'package:quadrille/features/settings/settings_providers.dart';
import 'package:quadrille/features/timer/timer_providers.dart';

class _Notifications extends Mock implements NotificationService {}

class _LocalAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}

void main() {
  testWidgets('Voice cues switch persists and silences an active rest alert', (
    tester,
  ) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final notifications = _Notifications();
    final scheduled = Completer<void>();
    registerFallbackValue(DateTime(2026));
    when(
      () => notifications.cancel(stillOwned: any(named: 'stillOwned')),
    ).thenAnswer((_) async {});
    when(
      () => notifications.scheduleRestComplete(
        endsAt: any(named: 'endsAt'),
        title: any(named: 'title'),
        body: any(named: 'body'),
        voiceCuesEnabled: any(named: 'voiceCuesEnabled'),
      ),
    ).thenAnswer((call) async {
      if (call.namedArguments[#voiceCuesEnabled] == false &&
          !scheduled.isCompleted) {
        scheduled.complete();
      }
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(notifications),
        authControllerProvider.overrideWith(_LocalAuth.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.runAsync(() async {
      // A saved rest, as on app reopen; no platform audio is needed to start it.
      await db.customStatement(
        '''INSERT INTO active_timers
        (id, started_at, ends_at, duration_seconds, status)
        VALUES ('singleton', ?, ?, 90, 'running')''',
        [
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          DateTime.now()
                  .add(const Duration(seconds: 90))
                  .millisecondsSinceEpoch ~/
              1000,
        ],
      );
      container.listen(restVoiceCueUpdatesProvider, (_, _) {});
      await container.read(settingsProvider.future);
      await container.read(authControllerProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Voice cues'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Voice cues'));
    await tester.pumpAndSettle();
    // Drift delivers real async work while widget callbacks use the fake clock.
    // Drain both until the platform notification submission is observed.
    for (var attempt = 0; !scheduled.isCompleted && attempt < 50; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(scheduled.isCompleted, isTrue);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect((await SettingsRepository(db).read()).voiceCuesEnabled, isFalse);
    });
    verify(
      () => notifications.scheduleRestComplete(
        endsAt: any(named: 'endsAt'),
        title: 'Rest complete',
        body: 'Time for your next set.',
        voiceCuesEnabled: false,
      ),
    ).called(1);
  });
}
