import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/features/session/session_starting.dart';
import 'package:quadrille/features/templates/presentation/template_detail_screen.dart';
import 'package:quadrille/features/today/presentation/today_screen.dart';
import 'session_starting_fixture.dart';

class AfterCommitRepository extends StartingRepository {
  AfterCommitRepository(super.db);
  final committed = Completer<String>();
  final release = Completer<void>();
  @override
  Future<String> startFromTemplate(String templateId) async {
    final id = await super.startFromTemplate(templateId);
    committed.complete(id);
    await release.future;
    return id;
  }
}

enum StartInterruption {
  otherTab('Other tab', returnButton: 'Source tab', destination: '/other'),
  rootCover('Root cover', returnButton: 'Close cover', isCover: true),
  branchCover('Branch cover', returnButton: 'Close cover', isCover: true),
  replacement('Replace source');

  const StartInterruption(
    this.label, {
    this.returnButton,
    this.destination,
    this.isCover = false,
  });

  final String label;
  final String? returnButton;
  final String? destination;
  final bool isCover;
}

void main() {
  for (final entry in ['/', '/detail']) {
    for (final interruption in StartInterruption.values) {
      for (final fails in [false, true]) {
        for (final returnBeforeCompletion in [
          false,
          if (interruption.returnButton != null) true,
        ]) {
          testWidgets(
            entry == '/' &&
                    interruption == StartInterruption.otherTab &&
                    !fails &&
                    !returnBeforeCompletion
                ? 'Today start preserves a selected retained tab'
                : '$entry start ${fails ? 'failure' : 'success'} after ${interruption.label} '
                      '${returnBeforeCompletion ? 'returns before completion' : 'stays hidden through completion'}',
            (tester) async {
              final fixture = StartingFixture();
              await fixture.open();
              final router = await showStartingShell(tester, fixture, entry);
              final gate = StartingWait();
              fixture.aRepository.waiting = gate;
              fixture.aRepository.fail = fails;
              final handle = fixture.container.read(
                sessionStartingProvider(StartingFixture.templateId),
              );
              await tester.tap(startControl(entry));
              await tester.runAsync(() => gate.entered.future);
              await tester.tap(find.text(interruption.label));
              await drain(tester);
              final hiddenLocation = interruption.destination ?? entry;
              expect(
                router.routeInformationProvider.value.uri.path,
                hiddenLocation,
              );
              if (returnBeforeCompletion) {
                await returnToStart(tester, interruption);
              }
              gate.completion.complete();
              await drain(tester);
              expect(handle.isPending, isFalse);
              if (returnBeforeCompletion) {
                if (fails) {
                  expect(
                    find.textContaining('Please try again'),
                    findsOneWidget,
                  );
                  expect(router.routeInformationProvider.value.uri.path, entry);
                } else {
                  final saved = await tester.runAsync(
                    () => fixture.aRepository.watchActiveSession().first,
                  );
                  expect(find.text('Workout ${saved!.id}'), findsOneWidget);
                }
              } else {
                expect(
                  router.routeInformationProvider.value.uri.path,
                  hiddenLocation,
                );
                expect(find.textContaining('Please try again'), findsNothing);
                if (interruption == StartInterruption.otherTab) {
                  expect(find.text('Other destination'), findsOneWidget);
                } else if (interruption.isCover) {
                  expect(find.text('Close cover'), findsOneWidget);
                }
                await returnToStart(tester, interruption);
                expect(router.routeInformationProvider.value.uri.path, entry);
                expect(find.textContaining('Please try again'), findsNothing);
                if (fails) {
                  fixture.aRepository.fail = false;
                  await tester.tap(startControl(entry));
                  await drain(tester);
                  expect(
                    router.routeInformationProvider.value.uri.path,
                    startsWith('/session/'),
                  );
                } else if (entry == '/') {
                  expect(find.text('Resume'), findsOneWidget);
                }
              }
              await tester.runAsync(() async {
                expect(
                  (await fixture.aRepository.watchActiveSession().first)?.name,
                  fails && returnBeforeCompletion ? isNull : 'Push A',
                );
                expect(
                  await fixture.bRepository.watchActiveSession().first,
                  isNull,
                );
              });
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }

  testWidgets(
    'current Today success opens its workout after active-session emission',
    (tester) async {
      final fixture = StartingFixture();
      await fixture.open();
      final repository = AfterCommitRepository(fixture.a);
      fixture.aRepository = repository;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (_, _) => const NoTransitionPage(child: TodayScreen()),
          ),
          GoRoute(
            path: '/session/:id',
            pageBuilder: (_, state) => NoTransitionPage(
              child: Scaffold(
                body: Text('Workout ${state.pathParameters['id']}'),
              ),
            ),
          ),
        ],
      );
      addTearDown(() async {
        if (!repository.release.isCompleted) repository.release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await drain(tester);
        router.dispose();
        await fixture.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await drain(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Push A'));
      final id = await tester.runAsync(() => repository.committed.future);
      await drain(tester);
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      repository.release.complete();
      await drain(tester);
      expect(router.routeInformationProvider.value.uri.path, '/session/$id');
    },
  );
}

Finder startControl(String entry) => entry == '/'
    ? find.widgetWithText(ListTile, 'Push A')
    : find.byTooltip('Start workout');

Future<void> returnToStart(
  WidgetTester tester,
  StartInterruption interruption,
) async {
  if (interruption.returnButton case final label?) {
    await tester.tap(find.text(label));
  }
  await drain(tester);
}

Future<GoRouter> showStartingShell(
  WidgetTester tester,
  StartingFixture fixture,
  String entry,
) async {
  final root = GlobalKey<NavigatorState>();
  final branch = GlobalKey<NavigatorState>();
  final revision = ValueNotifier(0);
  final router = GoRouter(
    navigatorKey: root,
    initialLocation: entry,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, navigation) => Scaffold(
          appBar: AppBar(
            toolbarHeight: 100,
            title: Wrap(
              children: [
                TextButton(
                  onPressed: () => navigation.goBranch(0),
                  child: const Text('Source tab'),
                ),
                TextButton(
                  onPressed: () => navigation.goBranch(1),
                  child: Text(StartInterruption.otherTab.label),
                ),
                for (final target in [root, branch])
                  TextButton(
                    onPressed: () => target.currentState!.push<void>(
                      MaterialPageRoute(
                        builder: (context) => Scaffold(
                          body: Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Close cover'),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: Text(
                      (identical(target, root)
                              ? StartInterruption.rootCover
                              : StartInterruption.branchCover)
                          .label,
                    ),
                  ),
                TextButton(
                  onPressed: () => revision.value++,
                  child: Text(StartInterruption.replacement.label),
                ),
              ],
            ),
          ),
          body: navigation,
        ),
        branches: [
          StatefulShellBranch(
            navigatorKey: branch,
            routes: [
              GoRoute(
                path: entry,
                builder: (_, _) => ValueListenableBuilder<int>(
                  valueListenable: revision,
                  builder: (_, value, _) => entry == '/'
                      ? TodayScreen(key: ValueKey(value))
                      : TemplateDetailScreen(
                          key: ValueKey(value),
                          templateId: StartingFixture.templateId,
                        ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/other',
                builder: (_, _) =>
                    const Scaffold(body: Text('Other destination')),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/session/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Workout ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
    router.dispose();
    revision.dispose();
    await fixture.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await drain(tester);
  return router;
}
