import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';

import '../session/session_starting_fixture.dart' show drain;
import 'template_editing_fixture.dart';

void main() {
  late TemplateEditingFixture fixture;
  setUp(() async {
    fixture = TemplateEditingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  for (final editing in [false, true]) {
    testWidgets(
      '${editing ? 'Edit' : 'Add'} cannot save into a later profile',
      (tester) async {
        await showTemplateDetail(tester, fixture);
        await openTemplateEditor(tester, editing: editing);
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'Changed in A',
        );
        fixture.switchToB();
        await drain(tester);
        final save = find.text(editing ? 'Save row' : 'Add row');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await drain(tester);
        final rows = await tester.runAsync(
          () => fixture.bRepository.watchExercises('t1').first,
        );
        expect(rows!.map((row) => row.displayName), ['Bench Press']);
        expect(
          find.text('This editor is no longer current. Close and reopen it.'),
          findsOneWidget,
        );
        expect(
          tester.widget<FilledButton>(editorSave(editing)).onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${editing ? 'Edit' : 'Add'} disables the pending form and shares taps',
      (tester) async {
        await showTemplateDetail(tester, fixture);
        await openTemplateEditor(tester, editing: editing);
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'Changed in A',
        );
        final gate = EditingWait();
        fixture.aRepository.waiting = gate;
        await tester.ensureVisible(editorSave(editing));
        final save = tester
            .widget<FilledButton>(editorSave(editing))
            .onPressed!;
        save();
        save();
        await tester.pump();
        await tester.runAsync(() => gate.entered.future);
        expect(fixture.aRepository.submissions, 1);
        expect(
          tester.widget<FilledButton>(editorSave(editing)).onPressed,
          isNull,
        );
        expect(
          tester
              .widgetList<TextFormField>(find.byType(TextFormField))
              .every((f) => f.enabled == false),
          isTrue,
        );
        gate.completion.complete();
        await drain(tester);
        expect(
          find.text(editing ? 'Edit exercise row' : 'Add exercise row'),
          findsNothing,
        );
        final rows = await tester.runAsync(
          () => fixture.aRepository.watchExercises('t1').first,
        );
        expect(
          rows!.map((r) => r.displayName),
          editing ? ['Changed in A'] : ['Bench Press', 'Changed in A'],
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${editing ? 'Edit' : 'Add'} retains input after failure and retries',
      (tester) async {
        await showTemplateDetail(tester, fixture);
        await openTemplateEditor(tester, editing: editing);
        await tester.enterText(find.byType(TextFormField).at(1), 'Retry value');
        fixture.aRepository.fail = true;
        await saveTemplateEditor(tester, editing: editing);
        await drain(tester);
        expect(
          find.text('Could not save this row. Please try again.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).at(1))
              .controller!
              .text,
          'Retry value',
        );
        expect(
          tester.widget<FilledButton>(editorSave(editing)).onPressed,
          isNotNull,
        );
        fixture.aRepository.fail = false;
        await saveTemplateEditor(tester, editing: editing);
        await drain(tester);
        final rows = await tester.runAsync(
          () => fixture.aRepository.watchExercises('t1').first,
        );
        expect(rows!.last.displayName, 'Retry value');
        expect(tester.takeException(), isNull);
      },
    );

    for (final fails in [false, true]) {
      testWidgets(
        '${editing ? 'Edit' : 'Add'} suppresses an accepted ${fails ? 'failure' : 'success'} after profile change',
        (tester) async {
          final navigator = GlobalKey<NavigatorState>();
          await showTemplateDetail(tester, fixture, navigatorKey: navigator);
          await openTemplateEditor(tester, editing: editing);
          await tester.enterText(
            find.byType(TextFormField).at(1),
            'Changed in A',
          );
          final gate = EditingWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          await saveTemplateEditor(tester, editing: editing);
          await tester.runAsync(() => gate.entered.future);
          fixture.switchToB();
          await drain(tester);
          gate.completion.complete();
          await drain(tester);
          expect(
            find.text(editing ? 'Edit exercise row' : 'Add exercise row'),
            findsOneWidget,
          );
          expect(
            find.text('This editor is no longer current. Close and reopen it.'),
            findsOneWidget,
          );
          expect(
            find.text('Could not save this row. Please try again.'),
            findsNothing,
          );
          final rows = await tester.runAsync(
            () => fixture.bRepository.watchExercises('t1').first,
          );
          expect(rows!.map((r) => r.displayName), ['Bench Press']);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );

      for (final remove in [false, true]) {
        testWidgets(
          '${editing ? 'Edit' : 'Add'} ${fails ? 'failure' : 'success'} cannot affect a ${remove ? 'replacement' : 'covering'} route',
          (tester) async {
            final navigator = GlobalKey<NavigatorState>();
            await showTemplateDetail(tester, fixture, navigatorKey: navigator);
            await openTemplateEditor(tester, editing: editing);
            await tester.enterText(find.byType(TextFormField).at(1), 'Changed');
            final gate = EditingWait();
            fixture.aRepository.waiting = gate;
            fixture.aRepository.fail = fails;
            await saveTemplateEditor(tester, editing: editing);
            await tester.runAsync(() => gate.entered.future);
            if (remove) {
              navigator.currentState!.pop();
              await tester.pumpAndSettle();
            }
            final covered = showDialog<void>(
              context: navigator.currentContext!,
              builder: (_) => const AlertDialog(title: Text('Newer route')),
            );
            await tester.pumpAndSettle();
            gate.completion.complete();
            await drain(tester);
            expect(find.text('Newer route'), findsOneWidget);
            if (remove) {
              expect(
                find.text('Could not save this row. Please try again.'),
                findsNothing,
              );
            }
            navigator.currentState!.pop();
            await covered;
            await tester.pumpAndSettle();
            if (!remove) {
              expect(
                find.text(editing ? 'Edit exercise row' : 'Add exercise row'),
                findsOneWidget,
              );
              navigator.currentState!.pop();
              await tester.pumpAndSettle();
              await drain(tester);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'catalog retirement removes visible suggestions and disables editing',
    (tester) async {
      await showTemplateDetail(tester, fixture);
      await openTemplateEditor(tester, editing: false);
      await drain(tester);
      await tester.enterText(find.byType(TextFormField).at(1), 'catalog');
      await tester.pumpAndSettle();
      expect(find.text('A catalog'), findsOneWidget);
      fixture.switchToB();
      await drain(tester);
      expect(find.text('A catalog'), findsNothing);
      expect(find.text('B catalog'), findsNothing);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField).at(1)).enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a retained rendered row callback cannot bind to a new profile', (
    tester,
  ) async {
    await showTemplateDetail(tester, fixture);
    final callback = tester
        .widget<ListTile>(find.widgetWithText(ListTile, 'Bench Press'))
        .onTap!;
    fixture.switchToB();
    await drain(tester);
    callback();
    await tester.pumpAndSettle();
    expect(
      find.text('This editor is no longer current. Close and reopen it.'),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(editorSave(true)).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'catalog defaults, free-text unlinking, time targets and parsing remain intact',
    (tester) async {
      await tester.runAsync(
        () => ExerciseRepository(fixture.a).create(
          name: 'Timed Plank',
          loadKind: LoadKind.bodyweight,
          isUnilateral: true,
          defaultRestSeconds: 75,
        ),
      );
      await showTemplateDetail(tester, fixture);
      await openTemplateEditor(tester, editing: false);
      await drain(tester);
      await tester.enterText(find.byType(TextFormField).at(1), 'Timed');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Timed Plank'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(3))
            .controller!
            .text,
        '75s',
      );
      await tester.tap(find.text('Time (s)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '2A');
      await tester.enterText(find.byType(TextFormField).at(2), '4');
      await tester.enterText(find.byType(TextFormField).at(4), '30');
      await tester.enterText(find.byType(TextFormField).at(5), '45');
      await tester.enterText(find.byType(TextFormField).at(6), ' Hold steady ');
      await saveTemplateEditor(tester, editing: false);
      await drain(tester);
      var rows = await tester.runAsync(
        () => fixture.aRepository.watchExercises('t1').first,
      );
      final saved = rows!.last;
      expect(saved.exerciseId, isNotNull);
      expect(saved.loadKind, LoadKind.bodyweight);
      expect(saved.isUnilateral, isTrue);
      expect(saved.restSeconds, 75);
      expect(saved.durationMinSeconds, 30);
      expect(saved.durationMaxSeconds, 45);
      expect(saved.repMin, isNull);
      expect(saved.targetSets, 4);
      expect(saved.supersetGroup, '2');
      expect(saved.notes, 'Hold steady');
      await tester.tap(find.text('Timed Plank'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(1), ' Free text ');
      await tester.enterText(find.byType(TextFormField).at(3), 'invalid');
      await saveTemplateEditor(tester, editing: true);
      await drain(tester);
      rows = await tester.runAsync(
        () => fixture.aRepository.watchExercises('t1').first,
      );
      expect(rows!.last.exerciseId, isNull);
      expect(rows.last.displayName, 'Free text');
      expect(rows.last.restSeconds, 120);
    },
  );

  testWidgets(
    'name and order remain required and rep targets retain their defaults',
    (tester) async {
      await showTemplateDetail(tester, fixture);
      await openTemplateEditor(tester, editing: false);
      await tester.enterText(find.byType(TextFormField).at(0), '');
      await saveTemplateEditor(tester, editing: false);
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('Req.'), findsOneWidget);
      expect(fixture.aRepository.submissions, 0);
      await tester.enterText(find.byType(TextFormField).at(0), '3');
      await tester.enterText(find.byType(TextFormField).at(1), 'Press');
      await tester.enterText(find.byType(TextFormField).at(4), '8');
      await saveTemplateEditor(tester, editing: false);
      await drain(tester);
      final rows = await tester.runAsync(
        () => fixture.aRepository.watchExercises('t1').first,
      );
      expect(rows!.last.repMin, 8);
      expect(rows.last.repMax, 8);
      expect(rows.last.targetSets, 3);
      expect(rows.last.restSeconds, 120);
    },
  );
}
