import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';

void main() {
  for (final (rpe, partials, unilateral, kind, label)
      in <(double?, int?, bool, LoadKind, String)>[
        (null, null, false, LoadKind.externalWeight, '30 × 15'),
        (10, 4, false, LoadKind.externalWeight, '30 × 15 @0 +4p'),
        (9, null, false, LoadKind.externalWeight, '30 × 15 @1'),
        (8, 5, false, LoadKind.externalWeight, '30 × 15 @2 +5p'),
        (7, 3, false, LoadKind.externalWeight, '30 × 15 @3+ +3p'),
        (null, 4, false, LoadKind.bodyweight, '15 +4p'),
        (9, 4, true, LoadKind.externalWeight, '30 × 15/14 @1 +4p'),
        (9.5, null, false, LoadKind.externalWeight, '30 × 15 @0.5'),
        (null, null, false, LoadKind.timeOnly, '15s'),
      ]) {
    for (final readOnly in [false, true]) {
      testWidgets('completed set shows $label (readOnly=$readOnly)', (
        tester,
      ) async {
        final date = DateTime(2026);
        final row = SessionGridRow(
          exercise: SessionExercise(
            id: 'curl',
            sessionId: 'session',
            displayName: 'Cable Curl',
            orderLabel: '1',
            sortIndex: 0,
            plannedSets: 1,
            plannedRestSeconds: 90,
            isUnilateral: unilateral,
            loadKind: kind,
            createdAt: date,
            updatedAt: date,
          ),
          sets: [
            SetEntry(
              id: 'set',
              sessionExerciseId: 'curl',
              setNumber: 1,
              weight: 30,
              weightUnit: WeightUnit.lb,
              reps: 15,
              leftReps: unilateral ? 15 : null,
              rightReps: unilateral ? 14 : null,
              rpe: rpe,
              partials: partials,
              status: SetStatus.completed,
              completedAt: date,
              createdAt: date,
              updatedAt: date,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SessionExerciseCard(row: row, readOnly: readOnly),
            ),
          ),
        );
        expect(find.text(label), findsOneWidget);
      });
    }
  }
}
