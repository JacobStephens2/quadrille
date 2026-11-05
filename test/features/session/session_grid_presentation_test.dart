import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/history/presentation/session_history_detail_screen.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/today/presentation/today_screen.dart';

void main() {
  final date = DateTime(2026);
  final session = WorkoutSession(
    id: 'session',
    name: 'Push A',
    status: SessionStatus.completed,
    startedAt: date,
    createdAt: date,
    updatedAt: date,
  );
  final row = SessionGridRow(
    exercise: SessionExercise(
      id: 'bench',
      sessionId: session.id,
      displayName: 'Bench Press',
      orderLabel: '1',
      sortIndex: 10,
      plannedSets: 2,
      plannedRestSeconds: 90,
      isUnilateral: false,
      loadKind: LoadKind.externalWeight,
      createdAt: date,
      updatedAt: date,
    ),
    sets: [
      for (final number in [1, 2])
        SetEntry(
          id: 'set-$number',
          sessionExerciseId: 'bench',
          setNumber: number,
          weight: number == 1 ? 70 : null,
          reps: number == 1 ? 10 : null,
          weightUnit: WeightUnit.lb,
          status: number == 1 ? SetStatus.completed : SetStatus.pending,
          completedAt: number == 1 ? date : null,
          createdAt: date,
          updatedAt: date,
        ),
    ],
  );

  testWidgets('Today progress follows complete grid emissions', (tester) async {
    final grids = StreamController<List<SessionGridRow>>();
    addTearDown(grids.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionProvider.overrideWith((ref) => Stream.value(session)),
          sessionGridProvider(session.id).overrideWith((ref) => grids.stream),
        ],
        child: const MaterialApp(home: TodayScreen()),
      ),
    );
    await tester.pump();
    expect(find.textContaining('sets logged'), findsNothing);

    grids.add([row]);
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 sets logged'), findsOneWidget);
    grids.add([
      SessionGridRow(exercise: row.exercise, sets: [row.sets.first]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('1 of 1 sets logged'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recorded history renders the complete grid as read-only cards', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider(
            session.id,
          ).overrideWith((ref) => Stream.value(session)),
          sessionGridProvider(
            session.id,
          ).overrideWith((ref) => Stream.value([row])),
        ],
        child: MaterialApp(
          home: SessionHistoryDetailScreen(sessionId: session.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('70 × 10'), findsOneWidget);
    expect(find.textContaining('1 sets'), findsOneWidget);
    final card = tester.widget<SessionExerciseCard>(
      find.byType(SessionExerciseCard),
    );
    expect(card.readOnly, isTrue);
    expect(card.onTapSet, isNull);
    expect(find.byTooltip('Add set'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
