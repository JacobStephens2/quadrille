import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/app/router.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/features/exercises/presentation/exercises_screen.dart';

import '../session/session_starting_fixture.dart' show drain;
import 'catalog_editing_fixture.dart';

void main() {
  late CatalogEditingFixture fixture;
  setUp(() async {
    fixture = CatalogEditingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  const failureMessage = 'Could not save this exercise. Please try again.';

  void expectDisabled(WidgetTester tester, bool editing) {
    expect(tester.widget<FilledButton>(catalogSave(editing)).onPressed, isNull);
    expect(
      tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .every((field) => field.enabled == false),
      isTrue,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(
      tester
          .widgetList<DropdownButtonFormField<dynamic>>(
            find.byWidgetPredicate((w) => w is DropdownButtonFormField),
          )
          .every((field) => field.onChanged == null),
      isTrue,
    );
  }

  for (final editing in [false, true]) {
    testWidgets(
      '${editing ? 'Edit' : 'Add'} cannot save into a later profile',
      (tester) async {
        await showCatalog(tester, fixture, editing: editing);
        await openCatalogEditor(tester, editing);
        await tester.enterText(
          find.byType(TextFormField).first,
          'Changed in A',
        );
        fixture.switchToB();
        await drain(tester);
        await saveCatalogEditor(tester, editing);
        await drain(tester);
        final rows = await tester.runAsync(
          () => fixture.bRepository.watchAll().first,
        );
        expect(rows!.map((e) => e.name), ['B exercise']);
        final original = await tester.runAsync(
          () => fixture.aRepository.watchAll().first,
        );
        expect(original!.map((e) => e.name), ['A exercise']);
        expect(
          find.text('This editor is no longer current. Close and reopen it.'),
          findsOneWidget,
        );
        expect(
          tester.widget<FilledButton>(catalogSave(editing)).onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${editing ? 'Edit' : 'Add'} pending form freezes values and current success closes its sheet',
      (tester) async {
        await showCatalog(tester, fixture, editing: editing);
        await openCatalogEditor(tester, editing);
        await tester.enterText(find.byType(TextFormField).first, ' First ');
        final gate = CatalogWait();
        fixture.aRepository.waiting = gate;
        await tester.ensureVisible(catalogSave(editing));
        final save = tester
            .widget<FilledButton>(catalogSave(editing))
            .onPressed!;
        save();
        save();
        await tester.pump();
        await tester.runAsync(() => gate.entered.future);
        expectDisabled(tester, editing);
        expect(fixture.aRepository.submissions, 1);
        gate.completion.complete();
        await drain(tester);
        expect(find.byType(TextFormField), findsNothing);
        final rows = await tester.runAsync(
          () => fixture.aRepository.watchAll().first,
        );
        expect(rows!.last.name, 'First');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${editing ? 'Edit' : 'Add'} failure keeps editable values for retry',
      (tester) async {
        await showCatalog(tester, fixture, editing: editing);
        await openCatalogEditor(tester, editing);
        await tester.enterText(find.byType(TextFormField).first, 'Retry value');
        fixture.aRepository.fail = true;
        await saveCatalogEditor(tester, editing);
        await drain(tester);
        expect(find.text(failureMessage), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .controller!
              .text,
          'Retry value',
        );
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .enabled,
          isTrue,
        );
        await tester.enterText(find.byType(TextFormField).first, 'Corrected');
        fixture.aRepository.fail = false;
        await saveCatalogEditor(tester, editing);
        await drain(tester);
        expect(find.byType(TextFormField), findsNothing);
        final rows = await tester.runAsync(
          () => fixture.aRepository.watchAll().first,
        );
        expect(rows!.last.name, 'Corrected');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${editing ? 'Edit' : 'Add'} retained rendered callback captures its original owner',
      (tester) async {
        await showCatalog(tester, fixture, editing: editing);
        final callback = editing
            ? tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == 'Edit',
                    ),
                  )
                  .onPressed!
            : tester
                  .widget<FloatingActionButton>(
                    find.byType(FloatingActionButton),
                  )
                  .onPressed!;
        fixture.switchToB();
        await drain(tester);
        callback();
        await tester.pumpAndSettle();
        expectDisabled(tester, editing);
        expect(
          find.text('This editor is no longer current. Close and reopen it.'),
          findsOneWidget,
        );
        if (editing) {
          expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField).first)
                .controller!
                .text,
            'A exercise',
          );
        }
        final rows = await tester.runAsync(
          () => fixture.bRepository.watchAll().first,
        );
        expect(rows!.single.name, 'B exercise');
      },
    );

    for (final pending in [false, true]) {
      testWidgets(
        '${editing ? 'Edit' : 'Add'} cancellation ${pending ? 'during persistence' : 'before submission'} releases the sheet',
        (tester) async {
          final navigator = GlobalKey<NavigatorState>();
          await showCatalog(
            tester,
            fixture,
            editing: editing,
            navigator: navigator,
          );
          await openCatalogEditor(tester, editing);
          await tester.enterText(find.byType(TextFormField).first, 'Accepted');
          final gate = CatalogWait();
          if (pending) {
            fixture.aRepository.waiting = gate;
            await saveCatalogEditor(tester, editing);
            await tester.runAsync(() => gate.entered.future);
          }
          await tester.ensureVisible(find.text('Cancel'));
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.byType(TextFormField), findsNothing);
          if (pending) gate.completion.complete();
          await drain(tester);
          final rows = await tester.runAsync(
            () => fixture.aRepository.watchAll().first,
          );
          expect(
            rows!.map((e) => e.name),
            pending
                ? editing
                      ? ['Accepted']
                      : ['A exercise', 'Accepted']
                : ['A exercise'],
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final fails in [false, true]) {
      testWidgets(
        '${editing ? 'Edit' : 'Add'} accepted ${fails ? 'failure' : 'success'} becomes silent after retirement',
        (tester) async {
          await showCatalog(tester, fixture, editing: editing);
          await openCatalogEditor(tester, editing);
          await tester.enterText(find.byType(TextFormField).first, 'Accepted');
          final gate = CatalogWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          await saveCatalogEditor(tester, editing);
          await tester.runAsync(() => gate.entered.future);
          fixture.switchToB();
          await drain(tester);
          gate.completion.complete();
          await drain(tester);
          expectDisabled(tester, editing);
          expect(
            find.text('This editor is no longer current. Close and reopen it.'),
            findsOneWidget,
          );
          expect(find.text(failureMessage), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      for (final removed in [false, true]) {
        testWidgets(
          '${editing ? 'Edit' : 'Add'} ${fails ? 'failure' : 'success'} stays silent under a ${removed ? 'replacement' : 'covering'} route',
          (tester) async {
            final navigator = GlobalKey<NavigatorState>();
            await showCatalog(
              tester,
              fixture,
              editing: editing,
              navigator: navigator,
            );
            await openCatalogEditor(tester, editing);
            await tester.enterText(
              find.byType(TextFormField).first,
              'Accepted',
            );
            final gate = CatalogWait();
            fixture.aRepository.waiting = gate;
            fixture.aRepository.fail = fails;
            await saveCatalogEditor(tester, editing);
            await tester.runAsync(() => gate.entered.future);
            if (removed) {
              unawaited(
                navigator.currentState!.pushAndRemoveUntil(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Replacement')),
                  ),
                  (_) => false,
                ),
              );
            } else {
              unawaited(
                showDialog<void>(
                  context: navigator.currentContext!,
                  builder: (_) => const AlertDialog(title: Text('Covering')),
                ),
              );
            }
            await drain(tester);
            gate.completion.complete();
            await drain(tester);
            expect(
              find.text(removed ? 'Replacement' : 'Covering'),
              findsOneWidget,
            );
            expect(find.text(failureMessage), findsNothing);
            if (!removed) {
              navigator.currentState!.pop();
              await tester.pumpAndSettle();
              expect(find.byType(TextFormField), findsNWidgets(3));
              expect(find.text(failureMessage), findsNothing);
              expect(
                tester.widget<FilledButton>(catalogSave(editing)).onPressed,
                fails ? isNotNull : isNull,
              );
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final result in ['missing', 'failed']) {
    testWidgets(
      'detail hides retained Edit during replacement-profile loading and $result read',
      (tester) async {
        await showCatalog(tester, fixture, editing: true);
        expect(find.byTooltip('Edit'), findsOneWidget);
        final read = Completer<Exercise?>();
        fixture.bRepository.reading = read;
        fixture.switchToB();
        await drain(tester);
        expect(find.byTooltip('Edit'), findsNothing);
        if (result == 'missing') {
          read.complete(null);
        } else {
          read.completeError(StateError('Read failed'));
        }
        await drain(tester);
        expect(find.byTooltip('Edit'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final rest in ['1:30', 'not a duration']) {
    testWidgets(
      'form rejects blank name and preserves rest conversion for $rest',
      (tester) async {
        await showCatalog(tester, fixture, editing: false);
        await openCatalogEditor(tester, false);
        await tester.enterText(find.byType(TextFormField).first, '  ');
        await saveCatalogEditor(tester, false);
        await tester.pump();
        expect(find.text('Required'), findsOneWidget);
        expect(fixture.aRepository.submissions, 0);
        await tester.enterText(find.byType(TextFormField).first, 'Converted');
        await tester.enterText(find.byType(TextFormField).at(1), rest);
        await tester.enterText(find.byType(TextFormField).at(2), '  notes  ');
        await saveCatalogEditor(tester, false);
        await drain(tester);
        final rows = await tester.runAsync(
          () => fixture.aRepository.watchAll().first,
        );
        expect(rows!.last.defaultRestSeconds, rest == '1:30' ? 90 : 120);
        expect(rows.last.notes, 'notes');
      },
    );
  }

  for (final fails in [false, true]) {
    for (final cover in ['root dialog', 'inactive tab']) {
      testWidgets(
        'real shell $cover suppresses ${fails ? 'failure' : 'success'} without replay',
        (tester) async {
          final router = createRouter()..go('/exercises');
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await drain(tester);
            router.dispose();
          });
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: fixture.container,
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await drain(tester);
          await openCatalogEditor(tester, false);
          await tester.enterText(find.byType(TextFormField).first, 'Accepted');
          final gate = CatalogWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          await saveCatalogEditor(tester, false);
          await tester.runAsync(() => gate.entered.future);
          if (cover == 'root dialog') {
            unawaited(
              showDialog<void>(
                context: tester.element(find.byType(ExercisesScreen)),
                useRootNavigator: true,
                builder: (_) => const AlertDialog(title: Text('Root cover')),
              ),
            );
          } else {
            router.go('/history');
          }
          await drain(tester);
          gate.completion.complete();
          await drain(tester);
          if (cover == 'root dialog') {
            expect(find.text('Root cover'), findsOneWidget);
            Navigator.of(
              tester.element(find.text('Root cover')),
              rootNavigator: true,
            ).pop();
          } else {
            expect(router.routeInformationProvider.value.uri.path, '/history');
            router.go('/exercises');
          }
          await drain(tester);
          expect(find.byType(TextFormField), findsNWidgets(3));
          expect(find.text(failureMessage), findsNothing);
          expect(
            tester.widget<FilledButton>(catalogSave(false)).onPressed,
            fails ? isNotNull : isNull,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
