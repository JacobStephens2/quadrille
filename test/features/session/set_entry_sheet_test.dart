import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/domain/previous_session_exercise.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/set_entry_sheet.dart';

void main() {
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
