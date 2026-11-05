import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/previous_session_exercise.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/set_entry_sheet.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

import 'set_entry_fixture.dart';

void main() {
  testWidgets('closing a hold cancels expiry during the sheet exit animation', (
    tester,
  ) async {
    final f = await EntryFixture.create(tester);
    await f.showSheet(tester);
    await tester.tap(find.text('Log set when timer finishes'));
    await tester.tap(find.text('Start hold timer'));
    await tester.pump();
    Navigator.of(tester.element(find.text('Log set'))).pop();
    f.now = f.now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 250));
    await f.flush(tester);
    await tester.pumpAndSettle();
    expect(f.sessions.writes, isEmpty);
    expect(f.navigation.pops, 1);
  });

  for (final timed in [false, true]) {
    testWidgets(
      '${timed ? 'timed' : 'rep'} submission disables actions and dismisses once',
      (tester) async {
        final f = await EntryFixture.create(tester, timed: timed);
        f.sessions.persistence = Completer<void>();
        await f.showSheet(tester);
        await tester.tap(find.text('Log set'));
        await tester.pump();
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Skip'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Log set'),
              )
              .onPressed,
          isNull,
        );
        if (timed) {
          expect(
            tester
                .widget<TextField>(find.widgetWithText(TextField, 'Seconds'))
                .enabled,
            isFalse,
          );
          expect(
            tester
                .widget<SwitchListTile>(find.byType(SwitchListTile))
                .onChanged,
            isNull,
          );
          expect(
            tester
                .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'Start hold timer'),
                )
                .onPressed,
            isNull,
          );
        }
        expect(f.navigation.pops, 0);
        f.sessions.persistence!.complete();
        await f.flush(tester);
        await tester.pumpAndSettle();
        expect(f.navigation.pops, 1);
        expect(find.text('Log set'), findsNothing);
        await tester.pump();
        expect(f.navigation.pops, 1);
      },
    );
  }

  for (final automatic in [false, true]) {
    testWidgets(
      '${automatic ? 'automatic' : 'manual'} save error stays open and retry dismisses once',
      (tester) async {
        final f = await EntryFixture.create(tester, timed: automatic);
        f.sessions.failure = StateError('write failed');
        await f.showSheet(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Notes (optional)'),
          'keep me',
        );
        if (automatic) {
          await tester.tap(find.text('Log set when timer finishes'));
          await tester.tap(find.text('Start hold timer'));
          await tester.pump();
          f.now = f.now.add(const Duration(seconds: 2));
          await tester.pump(const Duration(milliseconds: 250));
        } else {
          await tester.tap(find.text('Log set'));
        }
        await f.flush(tester);
        expect(
          find.text('Could not save set. Please try again.'),
          findsOneWidget,
        );
        expect(f.navigation.pops, 0);
        expect(
          tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Notes (optional)'),
              )
              .controller!
              .text,
          'keep me',
        );
        expect(tester.takeException(), isNull);
        f.sessions.failure = null;
        await tester.tap(find.text('Log set'));
        await f.flush(tester);
        await tester.pumpAndSettle();
        expect(f.navigation.pops, 1);
        expect(find.text('Log set'), findsNothing);
        expect((await f.saved(tester)).notes, 'keep me');
      },
    );
  }

  testWidgets('closing during a save cannot dismiss a reopened sheet', (
    tester,
  ) async {
    final f = await EntryFixture.create(tester);
    f.sessions.persistence = Completer<void>();
    await f.showSheet(tester);
    await tester.tap(find.text('Log set'));
    await tester.pump();
    Navigator.of(tester.element(find.text('Log set'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    f.sessions.persistence!.complete();
    await f.flush(tester);
    await tester.pumpAndSettle();
    expect(find.text('Log set'), findsOneWidget);
    expect(f.navigation.pops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unilateral left and right inputs reach the entry draft', (
    tester,
  ) async {
    final f = await EntryFixture.create(tester, timed: false, unilateral: true);
    await f.showSheet(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Left reps'), '8');
    await tester.enterText(find.widgetWithText(TextField, 'Right reps'), '9');
    expect(find.widgetWithText(TextField, 'Reps'), findsNothing);
    await tester.tap(find.text('Skip'));
    await f.flush(tester);
    await tester.pumpAndSettle();
    final saved = await f.saved(tester);
    expect(saved.leftReps, 8);
    expect(saved.rightReps, 9);
    expect(saved.status, SetStatus.skipped);
    expect(f.navigation.pops, 1);
  });

  for (final (label, rpe, notation) in [
    ('0 RIR', 10.0, '@0'),
    ('1 RIR', 9.0, '@1'),
    ('2 RIR', 8.0, '@2'),
    ('3+ RIR', 7.0, '@3+'),
  ]) {
    testWidgets('saves, restores, and clears $label and partials', (
      tester,
    ) async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      final sessions = SessionRepository(db);
      late String sessionId;
      late SessionExercise exercise;
      late List<SetEntry> sets;
      await tester.runAsync(() async {
        final templates = TemplateRepository(db);
        final templateId = await templates.createTemplate(name: 'Pull A');
        await templates.addExercise(
          templateId,
          TemplateExerciseDraft(
            displayName: 'Cable Curl',
            orderLabel: '1',
            targetSets: 1,
            restSeconds: 0,
          ),
        );
        sessionId = await sessions.startFromTemplate(templateId);
        exercise = (await sessions.watchExercises(sessionId).first).single;
        sets = await sessions.watchSets(sessionId).first;
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: Scaffold(
              body: StreamBuilder<List<SetEntry>>(
                stream: sessions.watchSets(sessionId),
                initialData: sets,
                builder: (context, snapshot) {
                  final row = SessionGridRow(
                    exercise: exercise,
                    sets: snapshot.requireData,
                  );
                  return SessionExerciseCard(
                    row: row,
                    onTapSet: (set) =>
                        showSetEntrySheet(context, row: row, set: set),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Set 1').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Weight (lb)'),
        '30',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Reps'), '15');
      await tester.tap(find.text(label));
      await tester.tap(find.text('+ Partials'));
      await tester.pump();
      await tester.tap(find.byTooltip('Add partial rep'));
      await tester.pump();
      await tester.tap(find.byTooltip('Add partial rep'));
      await tester.pump();
      expect(find.text('+5p'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove partial rep'));
      await tester.pump();
      await tester.tap(find.text('Log set'));
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        sets = (await tester.runAsync(
          () => sessions.watchSets(sessionId).first,
        ))!;
        if (sets.single.status == SetStatus.completed) break;
      }
      await tester.pumpAndSettle();
      expect(sets.single.rpe, rpe);
      expect(sets.single.partials, 4);
      expect(find.text('30 × 15 $notation +4p'), findsOneWidget);

      await tester.tap(find.text('Set 1').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
            .selected,
        isTrue,
      );
      expect(find.text('+4p'), findsOneWidget);
      await tester.tap(find.text(label));
      await tester.tap(find.byTooltip('Clear partials'));
      await tester.pump();
      await tester.tap(find.text('Log set'));
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        sets = (await tester.runAsync(
          () => sessions.watchSets(sessionId).first,
        ))!;
        if (sets.single.rpe == null && sets.single.partials == null) break;
      }
      expect(sets.single.rpe, isNull);
      expect(sets.single.partials, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(db.close);
    });
  }

  for (final withHistory in [false, true]) {
    testWidgets('entry sheet fits mobile keyboard (history=$withHistory)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final date = DateTime(2026);
      final exercise = SessionExercise(
        id: 'bench',
        sessionId: 'session',
        displayName: 'Bench Press',
        orderLabel: '1',
        sortIndex: 0,
        plannedSets: 4,
        repMax: 10,
        plannedRestSeconds: 120,
        isUnilateral: false,
        loadKind: LoadKind.externalWeight,
        createdAt: date,
        updatedAt: date,
      );
      SetEntry set(int number, {bool completed = false}) => SetEntry(
        id: 'set-$number',
        sessionExerciseId: 'bench',
        setNumber: number,
        weight: completed ? 70 : null,
        weightUnit: WeightUnit.lb,
        reps: completed ? 10 : null,
        status: completed ? SetStatus.completed : SetStatus.pending,
        completedAt: completed ? date : null,
        createdAt: date,
        updatedAt: date,
      );
      final pending = set(1);
      final row = SessionGridRow(
        exercise: exercise,
        sets: [pending],
        previous: withHistory
            ? PreviousSessionExercise(
                exercise: exercise,
                sets: [for (var n = 1; n <= 4; n++) set(n, completed: true)],
              )
            : null,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showSetEntrySheet(context, row: row, set: pending),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Log set').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
