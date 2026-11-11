import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/features/templates/presentation/templates_screen.dart';
import 'package:quadrille/features/templates/presentation/template_detail_screen.dart';
import 'package:quadrille/features/templates/template_management.dart';

import '../session/session_starting_fixture.dart' show drain;
import 'template_management_fixture.dart';

void main() {
  late ManagementFixture fixture;
  setUp(() async {
    fixture = ManagementFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  Future<GoRouter> showScreen(
    WidgetTester tester, {
    bool detail = false,
    GlobalKey<NavigatorState>? navigatorKey,
    bool tabs = false,
  }) async {
    final templates = GoRoute(
      path: '/templates',
      builder: (_, _) => const TemplatesScreen(),
      routes: [
        GoRoute(
          path: ':id',
          builder: (_, state) =>
              TemplateDetailScreen(templateId: state.pathParameters['id']!),
        ),
      ],
    );
    final router = GoRouter(
      navigatorKey: navigatorKey,
      initialLocation: detail ? '/templates/t1' : '/templates',
      routes: [
        if (tabs)
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => Scaffold(
              body: shell,
              bottomNavigationBar: TextButton(
                onPressed: () => shell.goBranch(1),
                child: const Text('Other tab'),
              ),
            ),
            branches: [
              StatefulShellBranch(routes: [templates]),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/other',
                    builder: (_, _) =>
                        const Scaffold(body: Text('Other tab content')),
                  ),
                ],
              ),
            ],
          )
        else
          templates,
        GoRoute(
          path: '/newer',
          builder: (_, _) => const Scaffold(body: Text('Newer route')),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await drain(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
    return router;
  }

  Future<void> menu(WidgetTester tester, String action) async {
    await tester.tap(find.byType(PopupMenuButton<TemplateManagementOpening>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await drain(tester);
  }

  Finder button(bool rename) =>
      find.widgetWithText(FilledButton, rename ? 'Save' : 'Create');

  Future<void> openName(WidgetTester tester, bool rename) async {
    if (rename) {
      await menu(tester, 'Rename');
    } else {
      await tester.tap(find.text('Template'));
      await tester.pumpAndSettle();
    }
  }

  for (final rename in [false, true]) {
    testWidgets(
      '${rename ? 'rename' : 'create'} validates, cancels, retains input on failure and disables pending controls',
      (tester) async {
        final router = await showScreen(tester, detail: rename);
        await openName(tester, rename);
        await tester.enterText(find.byType(TextField), '   ');
        await tester.tap(button(rename));
        await tester.pump();
        expect(find.text('Name is required'), findsOneWidget);
        expect(fixture.aRepository.submissions, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(fixture.aRepository.submissions, 0);
        await openName(tester, rename);
        await tester.enterText(find.byType(TextField), ' Saved name ');
        final gate = ManagementGate();
        fixture.aRepository.gate = gate;
        fixture.aRepository.fail = true;
        final submit = tester.widget<FilledButton>(button(rename)).onPressed!;
        submit();
        submit();
        await tester.pump();
        await tester.runAsync(() => gate.entered.future);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(tester.widget<FilledButton>(button(rename)).onPressed, isNull);
        expect(fixture.aRepository.submissions, 1);
        gate.completion.complete();
        await drain(tester);
        expect(find.textContaining('Please try again'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          ' Saved name ',
        );
        expect(
          tester.widget<FilledButton>(button(rename)).onPressed,
          isNotNull,
        );
        fixture.aRepository.fail = false;
        fixture.aRepository.gate = null;
        await tester.tap(button(rename));
        await drain(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Saved name'), findsWidgets);
        expect(
          router.routeInformationProvider.value.uri.path,
          rename ? '/templates/t1' : startsWith('/templates/'),
        );
        expect(fixture.aRepository.submissions, 2);
        expect(tester.takeException(), isNull);
      },
    );

    for (final fails in [false, true]) {
      for (final destination in [
        'covering',
        'removed',
        'replaced',
        'inactive tab',
      ]) {
        testWidgets(
          '${rename ? 'rename' : 'create'} delayed ${fails ? 'failure' : 'success'} cannot affect $destination route',
          (tester) async {
            final navigator = GlobalKey<NavigatorState>();
            final router = await showScreen(
              tester,
              detail: rename,
              navigatorKey: navigator,
              tabs: destination == 'inactive tab',
            );
            await openName(tester, rename);
            await tester.enterText(find.byType(TextField), 'Accepted name');
            final gate = ManagementGate();
            fixture.aRepository.gate = gate;
            fixture.aRepository.fail = fails;
            await tester.tap(button(rename));
            await tester.runAsync(() => gate.entered.future);
            if (destination == 'removed' || destination == 'replaced') {
              navigator.currentState!.pop();
              await tester.pumpAndSettle();
              if (destination == 'replaced') {
                router.go('/newer');
              } else {
                unawaited(
                  showDialog<void>(
                    context: navigator.currentContext!,
                    builder: (_) =>
                        const AlertDialog(title: Text('Newer route')),
                  ),
                );
              }
            } else if (destination == 'covering') {
              unawaited(
                showDialog<void>(
                  context: navigator.currentContext!,
                  builder: (_) => const AlertDialog(title: Text('Newer route')),
                ),
              );
            } else {
              router.go('/other');
            }
            await drain(tester);
            gate.completion.complete();
            await drain(tester);
            expect(
              router.routeInformationProvider.value.uri.path,
              destination == 'inactive tab'
                  ? '/other'
                  : destination == 'covering' || destination == 'removed'
                  ? (rename ? '/templates/t1' : '/templates')
                  : '/newer',
            );
            if (destination != 'inactive tab') {
              expect(find.text('Newer route'), findsOneWidget);
            }
            expect(find.textContaining('Please try again'), findsNothing);
            await tester.runAsync(() async {
              final templates = await fixture.aRepository
                  .watchTemplates()
                  .first;
              expect(templates.any((t) => t.name == 'Accepted name'), !fails);
            });
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final action in ['Rename', 'Duplicate', 'Archive']) {
    testWidgets(
      '$action from a menu opened before profile switch never retargets B',
      (tester) async {
        await showScreen(tester, detail: true);
        await tester.tap(
          find.byType(PopupMenuButton<TemplateManagementOpening>),
        );
        await tester.pumpAndSettle();
        fixture.switchToB();
        await drain(tester);
        await tester.tap(find.text(action));
        await drain(tester);
        if (action == 'Rename' &&
            find.byType(TextField).evaluate().isNotEmpty) {
          expect(find.textContaining('Close and reopen'), findsOneWidget);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() async {
          for (final repo in [fixture.aRepository, fixture.bRepository]) {
            expect((await repo.watchTemplates().first).map((t) => t.name), [
              'Push A',
            ]);
            expect((await repo.watchTemplate('t1').first)!.archived, isFalse);
          }
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final action in ['Duplicate', 'Archive']) {
    testWidgets(
      '$action exposes retry after current failure and preserves successful destination',
      (tester) async {
        final router = await showScreen(tester, detail: true);
        fixture.aRepository.fail = true;
        await menu(tester, action);
        await drain(tester);
        expect(find.textContaining('Please try again'), findsOneWidget);
        expect(router.routeInformationProvider.value.uri.path, '/templates/t1');
        fixture.aRepository.fail = false;
        await tester.tap(find.text('Retry'));
        await drain(tester);
        expect(
          router.routeInformationProvider.value.uri.path,
          action == 'Archive' ? '/templates' : isNot('/templates/t1'),
        );
        expect(
          find.text(action == 'Archive' ? 'No templates yet' : 'Push A (copy)'),
          findsOneWidget,
        );
        expect(fixture.aRepository.submissions, 2);
        expect(tester.takeException(), isNull);
      },
    );

    for (final fails in [false, true]) {
      for (final destination in ['covering', 'replaced', 'inactive tab']) {
        testWidgets(
          '$action delayed ${fails ? 'failure' : 'success'} cannot affect $destination route',
          (tester) async {
            final navigator = GlobalKey<NavigatorState>();
            final router = await showScreen(
              tester,
              detail: true,
              navigatorKey: navigator,
              tabs: destination == 'inactive tab',
            );
            final gate = ManagementGate();
            fixture.aRepository.gate = gate;
            fixture.aRepository.fail = fails;
            await menu(tester, action);
            await tester.runAsync(() => gate.entered.future);
            expect(
              tester
                  .widget<PopupMenuButton<TemplateManagementOpening>>(
                    find.byType(PopupMenuButton<TemplateManagementOpening>),
                  )
                  .enabled,
              isFalse,
            );
            if (destination == 'covering') {
              unawaited(
                showDialog<void>(
                  context: navigator.currentContext!,
                  builder: (_) => const AlertDialog(title: Text('Newer route')),
                ),
              );
            } else {
              router.go(destination == 'inactive tab' ? '/other' : '/newer');
            }
            await drain(tester);
            gate.completion.complete();
            await drain(tester);
            expect(
              router.routeInformationProvider.value.uri.path,
              destination == 'covering'
                  ? '/templates/t1'
                  : destination == 'inactive tab'
                  ? '/other'
                  : '/newer',
            );
            expect(find.textContaining('Please try again'), findsNothing);
            if (destination == 'inactive tab') {
              expect(find.text('Other tab content'), findsOneWidget);
            } else {
              expect(find.text('Newer route'), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('create opened in A cannot write into replacement profile B', (
    tester,
  ) async {
    await showScreen(tester);
    await tester.tap(find.text('Template'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A only');
    fixture.switchToB();
    await drain(tester);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Create'),
      warnIfMissed: false,
    );
    await drain(tester);
    await tester.runAsync(() async {
      expect(
        (await fixture.aRepository.watchTemplates().first).map((t) => t.name),
        ['Push A'],
      );
      expect(
        (await fixture.bRepository.watchTemplates().first).map((t) => t.name),
        ['Push A'],
      );
    });
    expect(find.textContaining('Close and reopen'), findsOneWidget);
  });

  testWidgets('rename opened in A cannot write after A retires', (
    tester,
  ) async {
    await showScreen(tester, detail: true);
    await menu(tester, 'Rename');
    await tester.enterText(find.byType(TextField), 'A only');
    fixture.switchToB();
    await drain(tester);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Save'),
      warnIfMissed: false,
    );
    await drain(tester);
    await tester.runAsync(() async {
      expect(
        (await fixture.aRepository.watchTemplate('t1').first)!.name,
        'Push A',
      );
      expect(
        (await fixture.bRepository.watchTemplate('t1').first)!.name,
        'Push A',
      );
    });
    expect(find.textContaining('Close and reopen'), findsOneWidget);
  });
}
