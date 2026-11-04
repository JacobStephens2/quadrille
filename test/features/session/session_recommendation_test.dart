import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/active_session_screen.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/timer/timer_providers.dart';

(List<SessionGridRow>, SetEntry) _tiedGrid() {
  final stamp = DateTime(2026);
  SessionGridRow makeRow(String id, int sortIndex) => SessionGridRow(
    exercise: SessionExercise(
      id: id,
      sessionId: 'session',
      displayName: id,
      orderLabel: id,
      sortIndex: sortIndex,
      supersetGroup: '1',
      plannedSets: 3,
      plannedRestSeconds: 90,
      isUnilateral: false,
      loadKind: LoadKind.externalWeight,
      createdAt: stamp,
      updatedAt: stamp,
    ),
    sets: [
      for (var n = 1; n <= 3; n++)
        SetEntry(
          id: '$id-$n',
          sessionExerciseId: id,
          setNumber: n,
          weightUnit: WeightUnit.lb,
          status: SetStatus.pending,
          createdAt: stamp,
          updatedAt: stamp,
        ),
    ],
  );
  final a = makeRow('1A', 10);
  final b = makeRow('1B', 20);
  // Save 1A Set 2, then 1B Set 1 within the same persisted second.
  final a2 = a.sets[1].copyWith(
    status: SetStatus.completed,
    completedAt: Value(stamp),
  );
  final b1 = b.sets[0].copyWith(
    status: SetStatus.completed,
    completedAt: Value(stamp),
  );
  return (
    [
      SessionGridRow(exercise: a.exercise, sets: [a.sets[0], a2, a.sets[2]]),
      SessionGridRow(exercise: b.exercise, sets: [b1, b.sets[1], b.sets[2]]),
    ],
    b1,
  );
}

void main() {
  test('next badge agrees with the last logged set when timestamps tie', () {
    final (rows, b1) = _tiedGrid();
    final timerNext = nextPendingSessionSet(rows, after: b1);
    final badgeNext = nextPendingSessionSet(rows);
    expect(timerNext?.set.id, '1A-1');
    expect(badgeNext?.set.id, timerNext?.set.id);
  });

  testWidgets('next badge agrees with the timer when timestamps tie', (
    tester,
  ) async {
    final (rows, b1) = _tiedGrid();
    final timerNext = nextPendingSessionSet(rows, after: b1);
    expect(timerNext?.set.id, '1A-1');
    final now = DateTime.now();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider('session').overrideWith((ref) => Stream.value(null)),
          sessionGridProvider('session').overrideWithValue(AsyncData(rows)),
          activeTimerProvider.overrideWith(
            (ref) => Stream.value(
              ActiveTimer(
                id: 'singleton',
                sessionId: 'session',
                sessionExerciseId: timerNext!.exercise.id,
                label: timerNext.label,
                startedAt: now,
                endsAt: now.add(const Duration(seconds: 90)),
                durationSeconds: 90,
                status: TimerStatus.running,
              ),
            ),
          ),
          timerTickProvider.overrideWith((ref) => const Stream<int>.empty()),
        ],
        child: const MaterialApp(
          home: ActiveSessionScreen(sessionId: 'session'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(timerNext!.label), findsOneWidget);
    final aCard = find.byWidgetPredicate(
      (widget) =>
          widget is SessionExerciseCard && widget.row.exercise.id == '1A',
    );
    expect(aCard, findsOneWidget);
    expect(
      tester.widget<SessionExerciseCard>(aCard).nextSetId,
      timerNext.set.id,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
