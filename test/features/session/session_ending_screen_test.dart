import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/presentation/active_session_screen.dart';
import 'package:quadrille/features/session/session_ending.dart';

import 'session_ending_fixture.dart';

void main() {
  late EndingFixture fixture;
  late GoRouter router;

  setUp(() async {
    fixture = EndingFixture();
    await fixture.open();
    router = GoRouter(
      initialLocation: '/session',
      routes: [
        GoRoute(
          path: '/session',
          builder: (_, _) => const HeroMode(
            enabled: false,
            child: ActiveSessionScreen(sessionId: EndingFixture.sessionId),
          ),
        ),
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Today destination')),
        ),
        GoRoute(
          path: '/history',
          builder: (_, _) => const Scaffold(body: Text('History destination')),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await fixture.close();
  });

  Future<void> showSession(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await drain(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  Future<void> openDialog(
    WidgetTester tester,
    SessionEndingIntent intent,
  ) async {
    if (intent == SessionEndingIntent.finish) {
      await tester.tap(find.text('Finish'));
    } else {
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard session'));
    }
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester, SessionEndingIntent intent) async {
    await tester.tap(
      find.widgetWithText(
        FilledButton,
        intent == SessionEndingIntent.finish ? 'Finish' : 'Discard',
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'switching profiles during Finish cancellation never ends the copied workout',
    (tester) async {
      await showSession(tester);
      final gate = EndingWait();
      fixture.notifications.cancelling = gate;
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
      await tester.pump();
      await tester.runAsync(() => gate.entered.future);
      fixture.switchTo('b');
      await tester.pump();
      gate.completion.complete();
      await drain(tester);

      await tester.runAsync(() async {
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect((await fixture.session(fixture.b)).status, SessionStatus.active);
        expect(await fixture.timer(fixture.b), isNotNull);
      });
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      expect(find.text('History destination'), findsNothing);
    },
  );

  for (final intent in SessionEndingIntent.values) {
    testWidgets('$intent confirmation cancellation has no effects', (
      tester,
    ) async {
      await showSession(tester);
      await openDialog(tester, intent);
      await tester.tap(
        find.text(
          intent == SessionEndingIntent.finish ? 'Keep going' : 'Cancel',
        ),
      );
      await drain(tester);
      await tester.runAsync(() async {
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect((await fixture.session(fixture.a)).deletedAt, isNull);
        expect(await fixture.timer(fixture.a), isNotNull);
      });
      expect(fixture.notifications.cancellations, 0);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
    });

    testWidgets(
      '$intent shows pending, disables ending controls, and navigates on success',
      (tester) async {
        await showSession(tester);
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        await openDialog(tester, intent);
        await confirm(tester, intent);
        await tester.runAsync(() => gate.entered.future);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Ending…'), findsOneWidget);
        expect(
          tester
              .widget<FloatingActionButton>(find.byType(FloatingActionButton))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<PopupMenuButton<String>>(
                find.byType(PopupMenuButton<String>),
              )
              .enabled,
          isFalse,
        );
        gate.completion.complete();
        await drain(tester);
        expect(
          find.text(
            intent == SessionEndingIntent.finish
                ? 'History destination'
                : 'Today destination',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('$intent displays a cancellation error and permits retry', (
      tester,
    ) async {
      await showSession(tester);
      fixture.notifications.fail = true;
      await openDialog(tester, intent);
      await confirm(tester, intent);
      await drain(tester);
      expect(find.textContaining('Please try again'), findsOneWidget);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      fixture.notifications.fail = false;
      await openDialog(tester, intent);
      await confirm(tester, intent);
      await drain(tester);
      expect(
        find.text(
          intent == SessionEndingIntent.finish
              ? 'History destination'
              : 'Today destination',
        ),
        findsOneWidget,
      );
    });

    testWidgets('$intent obsolete dialog cannot act after A-to-B-to-A', (
      tester,
    ) async {
      await showSession(tester);
      await openDialog(tester, intent);
      fixture.switchTo('b');
      fixture.switchTo('a');
      await confirm(tester, intent);
      await drain(tester);
      expect(fixture.notifications.cancellations, 0);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      await tester.runAsync(() async {
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect((await fixture.session(fixture.a)).deletedAt, isNull);
        expect(await fixture.timer(fixture.a), isNotNull);
      });
    });

    testWidgets(
      '$intent settles same-owner work after screen removal without UI updates',
      (tester) async {
        await showSession(tester);
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        await openDialog(tester, intent);
        await confirm(tester, intent);
        await tester.runAsync(() => gate.entered.future);
        router.go('/');
        await drain(tester);
        gate.completion.complete();
        await drain(tester);
        expect(find.text('Today destination'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final saved = await fixture.session(fixture.a);
          if (intent == SessionEndingIntent.finish) {
            expect(saved.status, SessionStatus.completed);
          } else {
            expect(saved.deletedAt, isNotNull);
          }
        });
      },
    );
  }

  testWidgets('an unavailable workout stays open with an explanation', (
    tester,
  ) async {
    await fixture.sessions(fixture.a).completeSession(EndingFixture.sessionId);
    await showSession(tester);
    await openDialog(tester, SessionEndingIntent.finish);
    await confirm(tester, SessionEndingIntent.finish);
    await drain(tester);
    expect(find.textContaining('no longer active'), findsOneWidget);
    expect(find.byType(ActiveSessionScreen), findsOneWidget);
    expect(fixture.notifications.cancellations, 0);
  });
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
