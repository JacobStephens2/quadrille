import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../session/session_starting_fixture.dart' show drain;
import 'template_editing_fixture.dart';

void main() {
  late TemplateEditingFixture fixture;
  setUp(() async {
    fixture = TemplateEditingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  Future<void> confirm(WidgetTester tester) async {
    await tester.drag(find.byType(Dismissible).first, const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete row?'), findsOneWidget);
  }

  Finder deleteButton() => find.widgetWithText(FilledButton, 'Delete');

  testWidgets(
    'cancelling swipe deletion leaves the row visible without writing',
    (tester) async {
      await showTemplateDetail(tester, fixture);
      await confirm(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Bench Press'), findsOneWidget);
      expect(fixture.aRepository.submissions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed deletion stays visible, retries, then the stream removes one tombstoned row',
    (tester) async {
      await showTemplateDetail(tester, fixture);
      await confirm(tester);
      fixture.aRepository.fail = true;
      await tester.tap(deleteButton());
      await drain(tester);
      expect(
        find.text('Could not delete this row. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('Bench Press'), findsOneWidget);
      expect(tester.widget<FilledButton>(deleteButton()).onPressed, isNotNull);
      fixture.aRepository.fail = false;
      final gate = EditingWait();
      fixture.aRepository.waiting = gate;
      final submit = tester.widget<FilledButton>(deleteButton()).onPressed!;
      submit();
      submit();
      await tester.pump();
      await tester.runAsync(() => gate.entered.future);
      expect(tester.widget<FilledButton>(deleteButton()).onPressed, isNull);
      expect(find.text('Bench Press'), findsOneWidget);
      expect(
        fixture.aRepository.submissions,
        2,
      ); // one failed attempt, one pending retry
      gate.completion.complete();
      await drain(tester);
      expect(find.text('Delete row?'), findsNothing);
      expect(find.text('Bench Press'), findsNothing);
      expect(find.text('No exercises in this template'), findsOneWidget);
      expect(
        await tester.runAsync(
          () => fixture.aRepository.watchExercises('t1').first,
        ),
        isEmpty,
      );
      expect(fixture.aRepository.submissions, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'profile change while confirming disables deletion and leaves both rows',
    (tester) async {
      await showTemplateDetail(tester, fixture);
      await confirm(tester);
      fixture.switchToB();
      await drain(tester);
      expect(
        find.text(
          'This confirmation is no longer current. Close and reopen it.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(deleteButton()).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Bench Press'), findsOneWidget);
      for (final repo in [fixture.aRepository, fixture.bRepository]) {
        expect(
          await tester.runAsync(() => repo.watchExercises('t1').first),
          hasLength(1),
        );
        expect(repo.submissions, 0);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'profile change suppresses accepted deletion ${fails ? 'error' : 'success'}',
      (tester) async {
        await showTemplateDetail(tester, fixture);
        await confirm(tester);
        final gate = EditingWait();
        fixture.aRepository.waiting = gate;
        fixture.aRepository.fail = fails;
        await tester.tap(deleteButton());
        await tester.runAsync(() => gate.entered.future);
        fixture.switchToB();
        await drain(tester);
        gate.completion.complete();
        await drain(tester);
        expect(find.text('Delete row?'), findsOneWidget);
        expect(
          find.text('Could not delete this row. Please try again.'),
          findsNothing,
        );
        expect(find.text('Bench Press'), findsOneWidget);
        expect(
          await tester.runAsync(
            () => fixture.bRepository.watchExercises('t1').first,
          ),
          hasLength(1),
        );
        expect(
          await tester.runAsync(
            () => fixture.aRepository.watchExercises('t1').first,
          ),
          fails ? hasLength(1) : isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final remove in [false, true]) {
      testWidgets(
        'deletion ${fails ? 'failure' : 'success'} cannot affect a ${remove ? 'replacement' : 'covering'} route',
        (tester) async {
          final navigator = GlobalKey<NavigatorState>();
          await showTemplateDetail(tester, fixture, navigatorKey: navigator);
          await confirm(tester);
          final gate = EditingWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          await tester.tap(deleteButton());
          await tester.runAsync(() => gate.entered.future);
          await completeUnderNewerRoute(
            tester,
            navigator,
            gate,
            removeOpening: remove,
            verifyWhileCovered: () {
              if (remove) {
                expect(
                  find.text('Could not delete this row. Please try again.'),
                  findsNothing,
                );
              }
            },
          );
          if (!remove) {
            expect(find.text('Delete row?'), findsOneWidget);
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
