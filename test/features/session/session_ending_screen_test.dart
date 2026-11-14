import 'dart:async';

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
  late GlobalKey<NavigatorState> branch;
  late ValueNotifier<int> revision;

  setUp(() async {
    fixture = EndingFixture();
    await fixture.open();
    branch = GlobalKey<NavigatorState>();
    revision = ValueNotifier(0);
    router = GoRouter(
      initialLocation: '/session',
      routes: [
        ShellRoute(
          navigatorKey: branch,
          builder: (_, _, child) => child,
          routes: [
            GoRoute(
              path: '/session',
              builder: (_, _) => ValueListenableBuilder<int>(
                valueListenable: revision,
                builder: (_, value, _) => HeroMode(
                  enabled: false,
                  child: ActiveSessionScreen(
                    key: ValueKey(value),
                    sessionId: EndingFixture.sessionId,
                  ),
                ),
              ),
            ),
          ],
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
    revision.dispose();
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

  Future<void> cover(WidgetTester tester, {bool root = true}) async {
    final source = tester.element(find.byType(ActiveSessionScreen));
    unawaited(
      Navigator.of(source, rootNavigator: root).push<void>(
        DialogRoute<void>(
          context: source,
          builder: (context) => AlertDialog(
            title: const Text('Newer destination'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close cover'),
              ),
            ],
          ),
        ),
      ),
    );
    await drain(tester);
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
    for (final unavailable in [false, true]) {
      testWidgets(
        '$intent retains a covered ${unavailable ? 'unavailable outcome' : 'error'} after reopening',
        (tester) async {
          if (unavailable) {
            await fixture
                .sessions(fixture.a)
                .completeSession(EndingFixture.sessionId);
          }
          await showSession(tester);
          final gate = EndingWait();
          if (unavailable) {
            fixture.waits.first.selecting = gate;
          } else {
            fixture.notifications.cancelling = gate;
            fixture.notifications.fail = true;
          }
          await openDialog(tester, intent);
          await confirm(tester, intent);
          await tester.runAsync(() => gate.entered.future);
          await cover(tester);
          gate.completion.complete();
          await drain(tester);
          expect(router.routeInformationProvider.value.uri.path, '/session');
          expect(find.text('Newer destination'), findsOneWidget);
          await tester.tap(find.text('Close cover'));
          await drain(tester);
          final feedback = unavailable
              ? 'no longer active'
              : 'Please try again';
          expect(find.textContaining(feedback), findsOneWidget);
          expect(find.text('Ending…'), findsNothing);
          expect(
            tester
                .widget<FloatingActionButton>(find.byType(FloatingActionButton))
                .onPressed,
            isNotNull,
          );
          router.go('/');
          await drain(tester);
          router.go('/session');
          await drain(tester);
          expect(find.textContaining(feedback), findsOneWidget);
          fixture.notifications.fail = false;
          await openDialog(tester, intent);
          await confirm(tester, intent);
          await drain(tester);
          if (unavailable) {
            expect(find.textContaining(feedback), findsOneWidget);
            expect(fixture.notifications.cancellations, 0);
          } else {
            expect(
              find.text(
                intent == SessionEndingIntent.finish
                    ? 'History destination'
                    : 'Today destination',
              ),
              findsOneWidget,
            );
          }
        },
      );
    }

    for (final replace in [false, true]) {
      testWidgets(
        '$intent confirmation rejects a ${replace ? 'replaced' : 'covered'} source',
        (tester) async {
          await showSession(tester);
          await openDialog(tester, intent);
          if (replace) {
            revision.value++;
            await drain(tester);
          } else {
            // A branch cover leaves the root confirmation available to answer.
            await cover(tester, root: false);
          }
          await confirm(tester, intent);
          await drain(tester);
          expect(router.routeInformationProvider.value.uri.path, '/session');
          expect(fixture.notifications.cancellations, 0);
          expect(find.text('Ending…'), findsNothing);
          await tester.runAsync(() async {
            final saved = await fixture.session(fixture.a);
            expect(saved.status, SessionStatus.active);
            expect(saved.deletedAt, isNull);
            expect(await fixture.timer(fixture.a), isNotNull);
          });
          if (!replace) {
            expect(find.text('Newer destination'), findsOneWidget);
            await tester.tap(find.text('Close cover'));
            await drain(tester);
          }
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
        },
      );
    }

    testWidgets('$intent uncovering before completion permits navigation', (
      tester,
    ) async {
      await showSession(tester);
      final gate = EndingWait();
      fixture.notifications.cancelling = gate;
      await openDialog(tester, intent);
      await confirm(tester, intent);
      await tester.runAsync(() => gate.entered.future);
      await cover(tester);
      await tester.tap(find.text('Close cover'));
      await drain(tester);
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
    });

    testWidgets(
      '$intent replacement at the same URI cannot inherit completion',
      (tester) async {
        await showSession(tester);
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        await openDialog(tester, intent);
        await confirm(tester, intent);
        await tester.runAsync(() => gate.entered.future);
        revision.value++;
        await drain(tester);
        expect(find.text('Ending…'), findsOneWidget);
        gate.completion.complete();
        await drain(tester);
        expect(router.routeInformationProvider.value.uri.path, '/session');
        expect(find.byType(ActiveSessionScreen), findsOneWidget);
        expect(find.text('Ending…'), findsNothing);
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

    testWidgets(
      '$intent completion preserves a root cover and releases pending',
      (tester) async {
        await showSession(tester);
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        await openDialog(tester, intent);
        await confirm(tester, intent);
        await tester.runAsync(() => gate.entered.future);
        await cover(tester);
        expect(router.routeInformationProvider.value.uri.path, '/session');
        gate.completion.complete();
        await drain(tester);
        expect(router.routeInformationProvider.value.uri.path, '/session');
        expect(find.text('Newer destination'), findsOneWidget);
        await tester.tap(find.text('Close cover'));
        await drain(tester);
        expect(find.byType(ActiveSessionScreen), findsOneWidget);
        expect(find.text('Ending…'), findsNothing);
        expect(
          tester
              .widget<FloatingActionButton>(find.byType(FloatingActionButton))
              .onPressed,
          isNotNull,
        );
        await tester.runAsync(() async {
          final saved = await fixture.session(fixture.a);
          if (intent == SessionEndingIntent.finish) {
            expect(saved.status, SessionStatus.completed);
          } else {
            expect(saved.deletedAt, isNotNull);
          }
          expect(
            (await fixture.session(fixture.b)).status,
            SessionStatus.active,
          );
          expect(await fixture.timer(fixture.a), isNull);
        });
      },
    );

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

  testWidgets('remounted screen releases failed pending ending for retry', (
    tester,
  ) async {
    await showSession(tester);
    final gate = EndingWait();
    fixture.notifications.cancelling = gate;
    fixture.notifications.fail = true;
    await openDialog(tester, SessionEndingIntent.finish);
    await confirm(tester, SessionEndingIntent.finish);
    await tester.runAsync(() => gate.entered.future);
    router.go('/');
    await drain(tester);
    router.go('/session');
    await drain(tester);
    expect(find.text('Ending…'), findsOneWidget);
    gate.completion.complete();
    await drain(tester);
    expect(
      fixture.container
          .read(sessionEndingProvider(EndingFixture.sessionId))
          .isPending,
      isFalse,
    );
    expect(
      {
        'pendingLabels': find.text('Ending…').evaluate().length,
        'retryMessages': find
            .textContaining('Please try again')
            .evaluate()
            .length,
        'finishEnabled':
            tester
                .widget<FloatingActionButton>(find.byType(FloatingActionButton))
                .onPressed !=
            null,
      },
      {'pendingLabels': 0, 'retryMessages': 1, 'finishEnabled': true},
    );
    fixture.notifications.fail = false;
    await openDialog(tester, SessionEndingIntent.finish);
    await confirm(tester, SessionEndingIntent.finish);
    await drain(tester);
    expect(find.text('History destination'), findsOneWidget);
  });

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
