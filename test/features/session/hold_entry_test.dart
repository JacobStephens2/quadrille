import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/hold_timer_controller.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/session/presentation/set_entry_sheet.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  testWidgets('timed hold opens with target seconds instead of reps', (
    tester,
  ) async {
    await _openHold(tester);
    expect(find.widgetWithText(TextField, 'Seconds'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Reps'), findsNothing);
    expect(find.widgetWithText(TextField, 'Weight (lb)'), findsNothing);
    await _closeHold(tester);
  });

  testWidgets(
    'hold timer uses entered seconds and allows logging on completion',
    (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      final fixture = await _openHold(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Seconds'), '2');
      await tester.tap(find.text('Start hold timer'));
      await tester.pump();
      expect(find.text('2s remaining'), findsOneWidget);
      await fixture.elapse(tester, const Duration(seconds: 1));
      expect(find.text('1s remaining'), findsOneWidget);
      await fixture.elapse(tester, const Duration(seconds: 1));
      expect(find.text('Hold complete'), findsOneWidget);
      expect(haptics, contains('HapticFeedbackType.heavyImpact'));
      expect((await fixture.readSets(tester)).first.status, SetStatus.pending);
      expect(find.text('Log set'), findsOneWidget);
      await tester.tap(find.text('Log set'));
      final saved = await fixture.waitForCompleted(tester);
      expect(saved.reps, 2);
      expect(find.text('2s'), findsOneWidget);
      await _closeHold(tester);
    },
  );

  testWidgets('hold timer can auto-log the set when it finishes', (
    tester,
  ) async {
    final fixture = await _openHold(tester);
    await tester.tap(find.text('Log set when timer finishes'));
    await tester.tap(find.text('Start hold timer'));
    await tester.pump();
    // A delayed redraw must use elapsed wall time, rather than counting ticks.
    fixture.now = fixture.now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(milliseconds: 250));
    final saved = await fixture.waitForCompleted(tester);
    expect(saved.reps, 20);
    expect(find.text('20s'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Seconds'), findsNothing);
    await _closeHold(tester);
  });

  testWidgets('holds carry prior seconds and retain logged seconds on reopen', (
    tester,
  ) async {
    final fixture = await _openHold(tester, priorSeconds: 23);
    expect(find.text('23'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Seconds'), '25');
    await tester.tap(find.text('Log set'));
    final saved = await fixture.waitForCompleted(tester, setNumber: 2);
    expect(saved.reps, 25);
    await tester.tap(find.text('Set 2').first);
    await tester.pumpAndSettle();
    expect(find.text('25'), findsOneWidget);
    await _closeHold(tester);
  });

  for (final (kind, target, label, value) in [
    (LoadKind.bodyweight, RepTarget.duration(20, 30), 'Seconds', '20'),
    (LoadKind.timeOnly, RepTarget.none, 'Seconds', ''),
    (
      LoadKind.externalWeight,
      const RepTarget(repMin: 8, durationMin: Duration(seconds: 20)),
      'Reps',
      '',
    ),
  ]) {
    testWidgets('$kind with target $target opens $label with "$value"', (
      tester,
    ) async {
      final fixture = await _openHold(tester, kind: kind, target: target);
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, label),
      );
      expect(field.controller!.text, value);
      expect(
        find.text('Start hold timer'),
        label == 'Seconds' ? findsOneWidget : findsNothing,
      );
      if (kind == LoadKind.bodyweight) {
        await tester.tap(find.text('Log set'));
        expect((await fixture.waitForCompleted(tester)).reps, 20);
        expect(find.text('20s'), findsOneWidget);
      }
      await _closeHold(tester);
    });
  }

  testWidgets('empty and zero seconds cannot start a hold countdown', (
    tester,
  ) async {
    final fixture = await _openHold(tester, target: RepTarget.none);
    for (final value in ['', '0']) {
      await tester.enterText(find.widgetWithText(TextField, 'Seconds'), value);
      await tester.tap(find.text('Start hold timer'));
      await tester.pumpAndSettle();
      expect(find.text('Enter seconds greater than zero'), findsOneWidget);
      expect(find.text('Stop hold timer'), findsNothing);
    }
    expect((await fixture.readSets(tester)).first.status, SetStatus.pending);
    await _closeHold(tester);
  });

  testWidgets('stopping or dismissing a hold cancels auto-log', (tester) async {
    final fixture = await _openHold(tester);
    await tester.tap(find.text('Log set when timer finishes'));
    await tester.tap(find.text('Start hold timer'));
    await tester.pump();
    await tester.tap(find.text('Stop hold timer'));
    await fixture.elapse(tester, const Duration(seconds: 21));
    expect(find.text('Hold complete'), findsNothing);
    expect((await fixture.readSets(tester)).first.status, SetStatus.pending);
    await tester.tap(find.text('Start hold timer'));
    await tester.pump();
    final context = tester.element(find.widgetWithText(TextField, 'Seconds'));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await fixture.elapse(tester, const Duration(seconds: 21));
    expect((await fixture.readSets(tester)).first.status, SetStatus.pending);
    expect(tester.takeException(), isNull);
    await _closeHold(tester);
  });

  testWidgets('duration hold entry fits a mobile keyboard', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await _openHold(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Log set').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Start hold timer'));
    expect(find.text('Start hold timer').hitTestable(), findsOneWidget);
    await _closeHold(tester);
  });
}

Future<_HoldFixture> _openHold(
  WidgetTester tester, {
  LoadKind kind = LoadKind.timeOnly,
  RepTarget? target,
  int? priorSeconds,
}) async {
  final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  final sessions = SessionRepository(db);
  late String sessionId;
  late SessionExercise exercise;
  late List<SetEntry> initialSets;
  await tester.runAsync(() async {
    final templates = TemplateRepository(db);
    final templateId = await templates.createTemplate(name: 'Holds');
    await templates.addExercise(
      templateId,
      TemplateExerciseDraft(
        displayName: 'Stomach Vacuum Hold',
        orderLabel: '1',
        targetSets: 2,
        restSeconds: 0,
        loadKind: kind,
        repTarget: target ?? RepTarget.duration(20, 20),
      ),
    );
    sessionId = await sessions.startFromTemplate(templateId);
    exercise = (await sessions.watchExercises(sessionId).first).single;
    initialSets = await sessions.watchSets(sessionId).first;
    if (priorSeconds != null) {
      await sessions.saveSet(initialSets.first.id, reps: priorSeconds);
      initialSets = await sessions.watchSets(sessionId).first;
    }
  });
  addTearDown(() => tester.runAsync(db.close));
  final fixture = _HoldFixture(sessions, sessionId);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        holdTimerNowProvider.overrideWithValue(() => fixture.now),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: StreamBuilder<List<SetEntry>>(
            stream: sessions.watchSets(sessionId),
            initialData: initialSets,
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
  await tester.tap(find.text('Set ${priorSeconds == null ? 1 : 2}').first);
  await tester.pumpAndSettle();
  return fixture;
}

class _HoldFixture {
  _HoldFixture(this.sessions, this.sessionId);

  final SessionRepository sessions;
  final String sessionId;
  DateTime now = DateTime(2026);

  Future<void> elapse(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
  }

  Future<List<SetEntry>> readSets(WidgetTester tester) async {
    return (await tester.runAsync(() => sessions.watchSets(sessionId).first))!;
  }

  Future<SetEntry> waitForCompleted(
    WidgetTester tester, {
    int setNumber = 1,
  }) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      final sets = await readSets(tester);
      final completed = sets.where(
        (s) => s.setNumber == setNumber && s.status == SetStatus.completed,
      );
      if (completed.isNotEmpty) {
        await tester.pumpAndSettle();
        return completed.last;
      }
    }
    throw TestFailure('Hold was not logged');
  }
}

Future<void> _closeHold(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}
