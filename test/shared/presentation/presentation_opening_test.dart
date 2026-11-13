import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/shared/presentation/presentation_opening.dart';

void main() {
  for (final rootModal in [true, false]) {
    final host = rootModal ? 'root dialog' : 'nearest sheet';

    testWidgets('$host permits its own current completion', (tester) async {
      final shell = await _Shell.mount(tester);
      final source = PresentationOpening.capture(shell.sourceContext);
      expect(source.isCurrent, isTrue);
      final modal = await shell.openModal(tester, source, root: rootModal);
      expect(source.isCurrent, isFalse);
      expect(modal.isCurrent, isTrue);
    });

    for (final rootCover in [true, false]) {
      testWidgets(
        '$host rejects a ${rootCover ? 'root' : 'branch'} cover and recovers',
        (tester) async {
          final shell = await _Shell.mount(tester);
          final source = PresentationOpening.capture(shell.sourceContext);
          final modal = await shell.openModal(tester, source, root: rootModal);
          final navigator = rootCover ? shell.root : shell.branch;
          unawaited(
            navigator.currentState!.push<void>(
              DialogRoute<void>(
                context: navigator.currentContext!,
                builder: (_) => const AlertDialog(title: Text('Cover')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          // Direct Navigator covers leave the GoRouter URI unchanged.
          expect(
            shell.router.routeInformationProvider.value.uri.path,
            '/source/leaf',
          );
          expect(modal.isCurrent, isFalse);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(modal.isCurrent, isTrue);
        },
      );
    }

    testWidgets(
      '$host rejects an inactive retained branch and recovers on return',
      (tester) async {
        final shell = await _Shell.mount(tester);
        final source = PresentationOpening.capture(shell.sourceContext);
        final modal = await shell.openModal(tester, source, root: rootModal);
        shell.navigation.goBranch(1);
        await tester.pumpAndSettle();
        expect(modal.isCurrent, isFalse);
        shell.navigation.goBranch(0);
        await tester.pumpAndSettle();
        expect(modal.isCurrent, isTrue);
      },
    );

    testWidgets('$host rejects a different URI even when routes survive', (
      tester,
    ) async {
      final shell = await _Shell.mount(tester);
      final source = PresentationOpening.capture(shell.sourceContext);
      final modal = await shell.openModal(tester, source, root: rootModal);
      shell.router.go('/source/leaf?view=other');
      await tester.pumpAndSettle();
      expect(shell.sourceContext.mounted, isTrue);
      expect(modal.isCurrent, isFalse);
      shell.router.go('/source/leaf');
      await tester.pumpAndSettle();
      expect(modal.isCurrent, isTrue);
    });

    testWidgets('$host rejects source removal', (tester) async {
      final shell = await _Shell.mount(tester);
      final sourceContext = shell.sourceContext;
      final source = PresentationOpening.capture(sourceContext);
      final modal = await shell.openModal(tester, source, root: rootModal);
      shell.router.go('/source');
      await tester.pumpAndSettle();
      expect(sourceContext.mounted, isFalse);
      expect(source.isCurrent, isFalse);
      expect(modal.isCurrent, isFalse);
    });

    testWidgets('$host cannot inherit eligibility from same-URI replacement', (
      tester,
    ) async {
      final shell = await _Shell.mount(tester);
      final originalContext = shell.sourceContext;
      final source = PresentationOpening.capture(originalContext);
      final modal = await shell.openModal(tester, source, root: rootModal);
      shell.sourceRevision++;
      shell.router.go('/source/leaf', extra: shell.sourceRevision);
      await tester.pumpAndSettle();
      expect(
        shell.router.routeInformationProvider.value.uri.path,
        '/source/leaf',
      );
      expect(originalContext.mounted, isFalse);
      expect(source.isCurrent, isFalse);
      expect(modal.isCurrent, isFalse);
      expect(
        PresentationOpening.capture(shell.sourceContext).isCurrent,
        rootModal ? isFalse : isTrue,
      );
    });

    testWidgets('$host rejects modal removal while the source survives', (
      tester,
    ) async {
      final shell = await _Shell.mount(tester);
      final source = PresentationOpening.capture(shell.sourceContext);
      final modal = await shell.openModal(tester, source, root: rootModal);
      (rootModal ? shell.root : shell.branch).currentState!.pop();
      await tester.pumpAndSettle();
      expect(source.isCurrent, isTrue);
      expect(modal.isCurrent, isFalse);
    });

    testWidgets('$host handles remain safe after disposal', (tester) async {
      final shell = await _Shell.mount(tester);
      final source = PresentationOpening.capture(shell.sourceContext);
      final modal = await shell.openModal(tester, source, root: rootModal);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(source.isCurrent, isFalse);
      expect(modal.isCurrent, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$host supports MaterialApp without GoRouter', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: Text('Source'));
            },
          ),
        ),
      );
      final source = PresentationOpening.capture(context);
      expect(source.isCurrent, isTrue);
      final modal = await _openModal(tester, context, source, root: rootModal);
      expect(modal.isCurrent, isTrue);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(modal.isCurrent, isFalse);
      expect(source.isCurrent, isTrue);
    });
  }

  for (final rootCover in [true, false]) {
    testWidgets(
      'source rejects a ${rootCover ? 'root' : 'branch'} cover and recovers',
      (tester) async {
        final shell = await _Shell.mount(tester);
        final source = PresentationOpening.capture(shell.sourceContext);
        final navigator = rootCover ? shell.root : shell.branch;
        unawaited(
          navigator.currentState!.push<void>(
            DialogRoute<void>(
              context: navigator.currentContext!,
              builder: (_) => const AlertDialog(title: Text('Cover')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(source.isCurrent, isFalse);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(source.isCurrent, isTrue);
      },
    );
  }

  testWidgets('effective source ticker eligibility matters at the same URI', (
    tester,
  ) async {
    final shell = await _Shell.mount(tester);
    final source = PresentationOpening.capture(shell.sourceContext);
    final modal = await shell.openModal(tester, source, root: true);
    shell.ticking.value = false;
    await tester.pumpAndSettle();
    expect(
      shell.router.routeInformationProvider.value.uri.path,
      '/source/leaf',
    );
    expect(modal.isCurrent, isFalse);
    shell.ticking.value = true;
    await tester.pumpAndSettle();
    expect(modal.isCurrent, isTrue);
  });

  testWidgets(
    'a context with no ModalRoute is ineligible, including modal binding',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final source = PresentationOpening.capture(context);
      expect(source.isCurrent, isFalse);
      expect(source.bindModal(context).isCurrent, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(PresentationOpening.capture(context).isCurrent, isFalse);
      expect(source.bindModal(context).isCurrent, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a valid source cannot bind a context with no modal identity', (
    tester,
  ) async {
    final shell = await _Shell.mount(tester);
    final source = PresentationOpening.capture(shell.sourceContext);
    final outsideRoute = tester.element(find.byType(MaterialApp));
    expect(source.isCurrent, isTrue);
    expect(source.bindModal(outsideRoute).isCurrent, isFalse);
  });
}

Future<PresentationOpening> _openModal(
  WidgetTester tester,
  BuildContext context,
  PresentationOpening source, {
  required bool root,
}) async {
  late PresentationOpening modal;
  Widget builder(BuildContext context) {
    modal = source.bindModal(context);
    return const AlertDialog(title: Text('Owned modal'));
  }

  if (root) {
    unawaited(showDialog<void>(context: context, builder: builder));
  } else {
    unawaited(showModalBottomSheet<void>(context: context, builder: builder));
  }
  await tester.pumpAndSettle();
  return modal;
}

class _Shell {
  final root = GlobalKey<NavigatorState>();
  final branch = GlobalKey<NavigatorState>();
  final ticking = ValueNotifier(true);
  int sourceRevision = 0;
  late final GoRouter router;
  late StatefulNavigationShell navigation;
  late BuildContext sourceContext;

  static Future<_Shell> mount(WidgetTester tester) async {
    final shell = _Shell();
    shell.router = GoRouter(
      navigatorKey: shell.root,
      initialLocation: '/source/leaf',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, navigation) {
            shell.navigation = navigation;
            return Scaffold(body: navigation);
          },
          branches: [
            StatefulShellBranch(
              navigatorKey: shell.branch,
              routes: [
                GoRoute(
                  path: '/source',
                  builder: (_, _) => const Scaffold(),
                  routes: [
                    GoRoute(
                      path: 'leaf',
                      pageBuilder: (_, _) => MaterialPage<void>(
                        key: ValueKey('source-${shell.sourceRevision}'),
                        child: ValueListenableBuilder<bool>(
                          valueListenable: shell.ticking,
                          builder: (_, enabled, child) =>
                              TickerMode(enabled: enabled, child: child!),
                          child: Builder(
                            builder: (context) {
                              shell.sourceContext = context;
                              return const Scaffold(body: Text('Source'));
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/other',
                  builder: (_, _) => const Scaffold(body: Text('Other branch')),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      shell.router.dispose();
      shell.ticking.dispose();
    });
    await tester.pumpWidget(MaterialApp.router(routerConfig: shell.router));
    await tester.pumpAndSettle();
    return shell;
  }

  Future<PresentationOpening> openModal(
    WidgetTester tester,
    PresentationOpening source, {
    required bool root,
  }) => _openModal(tester, sourceContext, source, root: root);
}
