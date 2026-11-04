import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/presentation/active_session_screen.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/timer/data/timer_repository.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

class _Notifications implements NotificationService {
  String? body;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  void scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) {
    this.body = body;
  }

  @override
  void cancel() {}
}

class _Watch implements WatchService {
  @override
  void updateSnapshot(WatchSnapshot snapshot) {}

  @override
  void clear() {}
}

class _LocalAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}

void main() {
  testWidgets('logging 1A routes the timer and next chip to 1B', (
    tester,
  ) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final sessions = SessionRepository(db);
    final timers = TimerRepository(db);
    final notifications = _Notifications();
    late String sessionId;
    await tester.runAsync(() async {
      final templates = TemplateRepository(db);
      final templateId = await templates.createTemplate(name: 'Paired sets');
      for (final (label, name, rest) in [
        ('1A', 'Bench Press', 90),
        ('1B', 'Weighted Chin-Up', 60),
      ]) {
        await templates.addExercise(
          templateId,
          TemplateExerciseDraft(
            displayName: name,
            orderLabel: label,
            restSeconds: rest,
          ),
        );
      }
      sessionId = await sessions.startFromTemplate(templateId);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(notifications),
          watchServiceProvider.overrideWithValue(_Watch()),
          authControllerProvider.overrideWith(_LocalAuth.new),
        ],
        child: MaterialApp(home: ActiveSessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(() async {
      await sessions.watchSets(sessionId).first;
    });
    await tester.pumpAndSettle();
    final a = find.byWidgetPredicate(
      (widget) =>
          widget is SessionExerciseCard &&
          widget.row.exercise.orderLabel == '1A',
    );
    await tester.tap(
      find.descendant(of: a, matching: find.text('Set 1')).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    ActiveTimer? timer;
    // Drain both Flutter's frame queue and Drift's database futures.
    for (var attempt = 0; attempt < 20 && timer == null; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      timer = await tester.runAsync<ActiveTimer?>(timers.read);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(timer?.label, '1B · Weighted Chin-Up (Set 1)');
    expect(timer?.durationSeconds, 90);
    expect(notifications.body, 'Next: 1B · Weighted Chin-Up (Set 1)');
    final b = find.byWidgetPredicate(
      (widget) =>
          widget is SessionExerciseCard &&
          widget.row.exercise.orderLabel == '1B',
    );
    expect(find.descendant(of: b, matching: find.text('Next')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  });
}
