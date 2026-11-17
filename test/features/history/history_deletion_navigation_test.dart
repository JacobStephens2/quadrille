import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/features/history/history_deletion.dart';
import 'package:quadrille/features/history/presentation/history_screen.dart';

import 'history_deletion_fixture.dart';
import 'history_screen_test.dart' show drain;

const failure = 'Could not delete workout. Please try again.';
const unavailable = 'This workout is unavailable. Close and reopen History.';

void main() {
  testWidgets(
    'current pending blocks duplicate submission and ordinary dismissal',
    (tester) async {
      final shell = await _DeletionShell.mount(tester);
      await shell.confirm(tester);
      final gate = DeletionWrite();
      shell.fixture.aRepository.waiting = gate;
      final delete = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
          .onPressed!;
      delete();
      delete();
      await tester.pump();
      await tester.runAsync(() => gate.entered.future);
      expect(shell.fixture.aRepository.submissions, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Deleting…'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      await shell.root.currentState!.maybePop();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(shell.confirmation.isActive, isTrue);
      gate.completion.complete();
      await drain(tester);
      expect(find.text('No completed workouts yet'), findsOneWidget);
      expect(shell.confirmation.isActive, isFalse);
      await shell.expectDestination(tester, deleted: true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('current unavailable is terminal and remains dismissible', (
    tester,
  ) async {
    final shell = await _DeletionShell.mount(tester);
    await shell.confirm(tester);
    final gate = DeletionWrite()..unavailable = true;
    shell.fixture.aRepository.waiting = gate;
    await shell.delete(tester, gate);
    gate.completion.complete();
    await drain(tester);
    expect(find.text(unavailable), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await drain(tester);
    expect(shell.confirmation.isActive, isFalse);
    await shell.expectDestination(tester, deleted: false);
  });

  for (final outcome in ['success', 'failure', 'unavailable']) {
    for (final navigation in [
      'root cover',
      'branch cover',
      'inactive branch',
      'URI change',
      'source replacement',
      'source removal',
      'modal removal',
    ]) {
      testWidgets('$navigation suppresses delayed $outcome without replay', (
        tester,
      ) async {
        final shell = await _DeletionShell.mount(tester);
        await shell.confirm(tester);
        final gate = DeletionWrite()
          ..fail = outcome == 'failure'
          ..unavailable = outcome == 'unavailable';
        shell.fixture.aRepository.waiting = gate;
        await shell.delete(tester, gate);
        await shell.navigate(tester, navigation);
        gate.completion.complete();
        await drain(tester);
        if (navigation != 'modal removal') {
          expect(shell.confirmation.isActive, isTrue);
        }
        await shell.expectDestination(tester, deleted: outcome == 'success');
        if (navigation.endsWith('cover')) {
          expect(shell.cover!.isActive, isTrue);
          shell.cover!.navigator!.pop();
        } else if (navigation == 'inactive branch') {
          expect(find.text('Other branch'), findsOneWidget);
          shell.navigation.goBranch(0);
        } else if (navigation == 'URI change') {
          shell.router.go('/source/leaf');
        }
        await drain(tester);
        // Include offstage widgets so hidden feedback cannot escape detection.
        expect(find.text(failure, skipOffstage: false), findsNothing);
        expect(find.text(unavailable, skipOffstage: false), findsNothing);
        if (navigation.endsWith('cover') ||
            navigation == 'inactive branch' ||
            navigation == 'URI change') {
          expect(find.text('Delete workout?'), findsOneWidget);
          expect(shell.confirmation.isActive, isTrue);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Delete'),
                )
                .onPressed,
            outcome == 'failure' ? isNotNull : isNull,
          );
          if (outcome == 'failure') {
            final retry = DeletionWrite()..fail = true;
            shell.fixture.aRepository.waiting = retry;
            await shell.delete(tester, retry);
            retry.completion.complete();
            await drain(tester);
            expect(find.text(failure), findsOneWidget);
          }
        }
        if (navigation == 'modal removal') {
          expect(find.text('Delete workout?'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final navigation in [
    'root cover',
    'branch cover',
    'inactive branch',
    'URI change',
  ]) {
    testWidgets('$navigation removed before completion restores eligibility', (
      tester,
    ) async {
      final shell = await _DeletionShell.mount(tester);
      await shell.confirm(tester);
      final gate = DeletionWrite();
      shell.fixture.aRepository.waiting = gate;
      await shell.delete(tester, gate);
      await shell.navigate(tester, navigation);
      if (navigation.endsWith('cover')) {
        shell.cover!.navigator!.pop();
      } else if (navigation == 'URI change') {
        shell.router.go('/source/leaf');
      } else {
        shell.navigation.goBranch(0);
      }
      await drain(tester);
      gate.completion.complete();
      await drain(tester);
      expect(shell.confirmation.isActive, isFalse);
      expect(find.text('No completed workouts yet'), findsOneWidget);
      await shell.expectDestination(tester, deleted: true);
      expect(tester.takeException(), isNull);
    });
  }

  for (final fail in [false, true]) {
    testWidgets(
      'profile retirement supersedes delayed ${fail ? 'error' : 'success'} and allows dismissal',
      (tester) async {
        final shell = await _DeletionShell.mount(tester);
        await shell.confirm(tester);
        final gate = DeletionWrite()..fail = fail;
        shell.fixture.aRepository.waiting = gate;
        await shell.delete(tester, gate);
        shell.fixture.switchToB();
        await drain(tester);
        expect(
          find.text('Your local profile changed. Close and reopen History.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
              .onPressed,
          isNotNull,
        );
        gate.completion.complete();
        await drain(tester);
        expect(find.text(failure), findsNothing);
        expect(shell.confirmation.isActive, isTrue);
        await shell.expectDestination(tester, deleted: !fail);
        await tester.tap(find.text('Cancel'));
        await drain(tester);
        expect(shell.confirmation.isActive, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'retained row callback cannot attach its old snapshot to a new profile',
    (tester) async {
      final shell = await _DeletionShell.mount(tester);
      final oldButton = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Delete workout',
            ),
          )
          .onPressed!;
      shell.fixture.switchToB();
      await drain(tester);
      oldButton();
      await drain(tester);
      expect(
        find.text('Your local profile changed. Close and reopen History.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
            .onPressed,
        isNull,
      );
      await shell.expectDestination(tester, deleted: false);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Real retained branches and root/branch modal stacks around HistoryScreen.
class _DeletionShell {
  _DeletionShell(this.fixture)
    : owner = fixture.container.read(historyDeletionProvider);

  final DeletionFixture fixture;
  final HistoryDeletion owner;
  final root = GlobalKey<NavigatorState>();
  final branch = GlobalKey<NavigatorState>();
  late final GoRouter router;
  late StatefulNavigationShell navigation;
  late Route<dynamic> confirmation;
  DialogRoute<void>? cover;
  int revision = 0;

  static Future<_DeletionShell> mount(WidgetTester tester) async {
    final fixture = DeletionFixture();
    await tester.runAsync(fixture.open);
    final shell = _DeletionShell(fixture);
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
                        key: ValueKey('history-${shell.revision}'),
                        child: const HistoryScreen(),
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
      await tester.pumpAndSettle();
      shell.router.dispose();
      await tester.runAsync(fixture.close);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(routerConfig: shell.router),
      ),
    );
    await drain(tester);
    return shell;
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Delete workout'));
    await tester.pumpAndSettle();
    confirmation = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
  }

  Future<void> delete(WidgetTester tester, DeletionWrite gate) async {
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.runAsync(() => gate.entered.future);
  }

  Future<void> expectDestination(
    WidgetTester tester, {
    required bool deleted,
  }) async {
    expect(
      await tester.runAsync(() => fixture.exists(fixture.aRepository)),
      !deleted,
    );
    expect(
      await tester.runAsync(() => fixture.exists(fixture.bRepository)),
      isTrue,
    );
    expect(fixture.bRepository.submissions, 0);
  }

  Future<void> navigate(WidgetTester tester, String change) async {
    switch (change) {
      case 'root cover':
      case 'branch cover':
        final navigator = change == 'root cover' ? root : branch;
        cover = DialogRoute<void>(
          context: navigator.currentContext!,
          builder: (_) => const AlertDialog(title: Text('Cover survives')),
        );
        unawaited(navigator.currentState!.push(cover!));
      case 'inactive branch':
        navigation.goBranch(1);
      case 'URI change':
        router.go('/source/leaf?later=true');
      case 'source replacement':
        revision++;
        router.go('/source/leaf', extra: revision);
      case 'source removal':
        router.go('/source');
      case 'modal removal':
        root.currentState!.pop();
    }
    await drain(tester);
    expect(fixture.container.read(historyDeletionProvider), same(owner));
  }
}
