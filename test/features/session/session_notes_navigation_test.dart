import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/features/history/presentation/session_history_detail_screen.dart';
import 'package:quadrille/features/session/presentation/active_session_screen.dart';
import 'package:quadrille/features/session/session_notes_editing.dart';

import 'session_notes_fixture.dart';
import 'session_starting_fixture.dart' show drain;

const failure = 'Could not save notes. Please try again.';

void main() {
  for (final active in [false, true]) {
    final entry = active ? 'Active workout' : 'History';
    testWidgets(
      '$entry current success freezes one attempt and closes its dialog',
      (tester) async {
        final shell = await _NotesShell.mount(tester, active: active);
        await shell.edit(tester);
        await tester.enterText(find.byType(TextField), ' First accepted text ');
        final gate = NotesWrite();
        shell.fixture.aRepository.waiting = gate;
        final save = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed!;
        save();
        save();
        await tester.pump();
        await tester.runAsync(() => gate.entered.future);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
              .onPressed,
          isNull,
        );
        await shell.root.currentState!.maybePop();
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        expect(shell.fixture.aRepository.submissions, 1);
        gate.completion.complete();
        await drain(tester);
        expect(find.byType(TextField), findsNothing);
        await shell.expectNotes(tester, 'First accepted text');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$entry current failure retains text and retries the latest draft',
      (tester) async {
        final shell = await _NotesShell.mount(tester, active: active);
        await shell.edit(tester);
        await tester.enterText(find.byType(TextField), 'Failed draft');
        final failed = NotesWrite()..fail = true;
        shell.fixture.aRepository.waiting = failed;
        await shell.save(tester, failed);
        failed.completion.complete();
        await drain(tester);
        expect(find.text(failure), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Failed draft',
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        await shell.expectNotes(tester, 'Original');
        await tester.enterText(find.byType(TextField), 'Latest draft');
        final retry = NotesWrite();
        shell.fixture.aRepository.waiting = retry;
        await shell.save(tester, retry);
        expect(find.text(failure), findsNothing);
        retry.completion.complete();
        await drain(tester);
        expect(find.byType(TextField), findsNothing);
        await shell.expectNotes(tester, 'Latest draft');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$entry retirement takes precedence over a delayed error', (
      tester,
    ) async {
      final shell = await _NotesShell.mount(tester, active: active);
      await shell.edit(tester);
      final gate = NotesWrite()..fail = true;
      shell.fixture.aRepository.waiting = gate;
      await shell.save(tester, gate);
      shell.fixture.switchToB();
      await drain(tester);
      expect(
        find.text(
          'Your local profile changed. Close and reopen session notes.',
        ),
        findsOneWidget,
      );
      gate.completion.complete();
      await drain(tester);
      expect(find.text(failure), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await shell.expectNotes(tester, 'Original');
      expect(tester.takeException(), isNull);
    });

    for (final navigation in [
      'root cover',
      'branch cover',
      'inactive branch',
      'source replacement',
      'source removal',
      'modal removal',
      'URI change',
    ]) {
      for (final fail in [false, true]) {
        testWidgets(
          '$entry $navigation suppresses delayed ${fail ? 'error' : 'success'} without replay',
          (tester) async {
            final shell = await _NotesShell.mount(tester, active: active);
            await shell.edit(tester);
            await tester.enterText(find.byType(TextField), 'Captured notes');
            final gate = NotesWrite()..fail = fail;
            shell.fixture.aRepository.waiting = gate;
            await shell.save(tester, gate);
            await shell.navigate(tester, navigation);
            gate.completion.complete();
            await drain(tester);
            if (navigation != 'modal removal') {
              expect(shell.editorRoute.isActive, isTrue);
            }
            await shell.expectNotes(
              tester,
              fail ? 'Original' : 'Captured notes',
            );
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
            expect(find.text(failure), findsNothing);
            if (navigation.endsWith('cover') ||
                navigation == 'inactive branch' ||
                navigation == 'URI change') {
              expect(find.byType(TextField), findsOneWidget);
              expect(
                tester
                    .widget<FilledButton>(
                      find.widgetWithText(FilledButton, 'Save'),
                    )
                    .onPressed,
                fail ? isNotNull : isNull,
              );
              if (fail) {
                final retry = NotesWrite()..fail = true;
                shell.fixture.aRepository.waiting = retry;
                await shell.save(tester, retry);
                retry.completion.complete();
                await drain(tester);
                expect(find.text(failure), findsOneWidget);
              }
            }
            if (navigation == 'modal removal') {
              expect(find.byType(TextField), findsNothing);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    for (final navigation in [
      'root cover',
      'branch cover',
      'inactive branch',
    ]) {
      testWidgets('$entry $navigation recovers before completion', (
        tester,
      ) async {
        final shell = await _NotesShell.mount(tester, active: active);
        await shell.edit(tester);
        await tester.enterText(
          find.byType(TextField),
          'Restored before completion',
        );
        final gate = NotesWrite();
        shell.fixture.aRepository.waiting = gate;
        await shell.save(tester, gate);
        await shell.navigate(tester, navigation);
        if (navigation.endsWith('cover')) {
          shell.cover!.navigator!.pop();
        } else {
          shell.navigation.goBranch(0);
        }
        await drain(tester);
        gate.completion.complete();
        await drain(tester);
        expect(find.byType(TextField), findsNothing);
        await shell.expectNotes(tester, 'Restored before completion');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      '$entry retained button cannot attach an old snapshot to a new profile',
      (tester) async {
        final shell = await _NotesShell.mount(tester, active: active);
        final oldButton = tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Edit session notes',
              ),
            )
            .onPressed!;
        shell.fixture.switchToB();
        await drain(tester);
        oldButton();
        await drain(tester);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNull,
        );
        expect(
          find.text(
            'Your local profile changed. Close and reopen session notes.',
          ),
          findsOneWidget,
        );
        await shell.expectNotes(tester, 'Original');
        expect(tester.takeException(), isNull);
      },
    );
  }
}

/// Real navigation through both notes entry points and root/branch stacks.
class _NotesShell {
  _NotesShell(this.fixture)
    : owner = fixture.container.read(sessionNotesEditingProvider);
  final NotesFixture fixture;
  final SessionNotesEditing owner;
  late Route<dynamic> editorRoute;
  final root = GlobalKey<NavigatorState>();
  final branch = GlobalKey<NavigatorState>();
  late final GoRouter router;
  late StatefulNavigationShell navigation;
  int revision = 0;
  DialogRoute<void>? cover;

  static Future<_NotesShell> mount(
    WidgetTester tester, {
    required bool active,
  }) async {
    final fixture = NotesFixture(active: active);
    await tester.runAsync(fixture.open);
    final shell = _NotesShell(fixture);
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
                        key: ValueKey('notes-${shell.revision}'),
                        child: active
                            ? const ActiveSessionScreen(sessionId: 'session')
                            : const SessionHistoryDetailScreen(
                                sessionId: 'session',
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

  Future<void> edit(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Edit session notes'));
    await tester.pumpAndSettle();
    editorRoute = ModalRoute.of(tester.element(find.byType(TextField)))!;
  }

  Future<void> save(WidgetTester tester, NotesWrite gate) async {
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.runAsync(() => gate.entered.future);
  }

  Future<void> expectNotes(WidgetTester tester, String expected) async {
    expect(
      await tester.runAsync(() => fixture.notes(fixture.aRepository)),
      expected,
    );
    expect(
      await tester.runAsync(() => fixture.notes(fixture.bRepository)),
      'Original',
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
      case 'source replacement':
        revision++;
        router.go('/source/leaf', extra: revision);
      case 'source removal':
        router.go('/source');
      case 'modal removal':
        root.currentState!.pop();
      case 'URI change':
        router.go('/source/leaf?later=true');
    }
    await drain(tester);
    expect(fixture.container.read(sessionNotesEditingProvider), same(owner));
  }
}
