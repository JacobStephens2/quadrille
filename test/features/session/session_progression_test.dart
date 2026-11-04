import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/domain/previous_session_exercise.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';

final _date = DateTime(2026);

SessionExercise exercise({
  int plannedSets = 4,
  int? repMax = 10,
  bool unilateral = false,
}) => SessionExercise(
  id: 'bench',
  sessionId: 'session',
  displayName: 'Bench Press',
  orderLabel: '1',
  sortIndex: 10,
  plannedSets: plannedSets,
  repMax: repMax,
  plannedRestSeconds: 120,
  isUnilateral: unilateral,
  loadKind: LoadKind.externalWeight,
  createdAt: _date,
  updatedAt: _date,
);

SetEntry loggedSet(
  int number, {
  double? weight = 70,
  int? reps = 10,
  int? left,
  int? right,
  SetStatus status = SetStatus.completed,
}) => SetEntry(
  id: 'set-$number',
  sessionExerciseId: 'bench',
  setNumber: number,
  weight: weight,
  reps: reps,
  leftReps: left,
  rightReps: right,
  weightUnit: WeightUnit.lb,
  status: status,
  completedAt: status == SetStatus.completed ? _date : null,
  createdAt: _date,
  updatedAt: _date,
);

SessionGridRow gridWithHistory(
  List<SetEntry> previousSets, {
  int previousPlannedSets = 4,
  int currentPlannedSets = 4,
  int? repMax = 10,
  bool unilateral = false,
  List<SetEntry> currentSets = const [],
}) => SessionGridRow(
  exercise: exercise(
    plannedSets: currentPlannedSets,
    repMax: repMax,
    unilateral: unilateral,
  ),
  sets: currentSets,
  previous: PreviousSessionExercise(
    exercise: exercise(
      plannedSets: previousPlannedSets,
      unilateral: unilateral,
    ),
    sets: previousSets,
  ),
);

void main() {
  test('four completed working sets at repMax are ready to progress', () {
    final row = gridWithHistory([for (var n = 1; n <= 4; n++) loggedSet(n)]);

    expect(row.isReadyToProgress, isTrue);
  });

  test('10 10 9 8 is not ready to progress', () {
    final row = gridWithHistory([
      loggedSet(1),
      loggedSet(2),
      loggedSet(3, reps: 9),
      loggedSet(4, reps: 8),
    ]);
    expect(row.isReadyToProgress, isFalse);
  });

  test('both unilateral sides must reach repMax on every set', () {
    final sets = [
      for (var n = 1; n <= 4; n++) loggedSet(n, left: 10, right: 11),
    ];
    expect(gridWithHistory(sets, unilateral: true).isReadyToProgress, isTrue);
    sets[3] = loggedSet(4, left: 10, right: 9);
    expect(gridWithHistory(sets, unilateral: true).isReadyToProgress, isFalse);
    sets[3] = loggedSet(4, left: 9, right: 10);
    expect(gridWithHistory(sets, unilateral: true).isReadyToProgress, isFalse);
    sets[3] = loggedSet(4, left: 10);
    expect(gridWithHistory(sets, unilateral: true).isReadyToProgress, isFalse);
  });

  test('missing planned sets cannot be replaced by bonus sets', () {
    final row = gridWithHistory([
      loggedSet(1),
      loggedSet(2),
      loggedSet(3),
      loggedSet(5),
    ]);
    expect(row.isReadyToProgress, isFalse);
  });

  test('non-working deleted and unstamped sets cannot qualify', () {
    final sets = [for (var n = 1; n <= 4; n++) loggedSet(n)];
    for (final status in SetStatus.values.where(
      (s) => s != SetStatus.completed,
    )) {
      sets[3] = loggedSet(4, status: status);
      expect(
        gridWithHistory(sets).isReadyToProgress,
        isFalse,
        reason: status.name,
      );
    }
    sets[3] = loggedSet(4).copyWith(deletedAt: Value(_date));
    expect(gridWithHistory(sets).isReadyToProgress, isFalse);
    sets[3] = loggedSet(4).copyWith(completedAt: const Value(null));
    expect(gridWithHistory(sets).isReadyToProgress, isFalse);
  });

  test('uses the previous plan when the current planned set count changes', () {
    final sets = [for (var n = 1; n <= 4; n++) loggedSet(n)];
    expect(
      gridWithHistory(sets, currentPlannedSets: 5).isReadyToProgress,
      isTrue,
    );
    expect(
      gridWithHistory(
        sets.take(3).toList(),
        currentPlannedSets: 3,
      ).isReadyToProgress,
      isFalse,
    );
  });

  test('history and a rep ceiling are both required', () {
    expect(
      SessionGridRow(exercise: exercise(), sets: []).isReadyToProgress,
      isFalse,
    );
    final sets = [for (var n = 1; n <= 4; n++) loggedSet(n)];
    expect(gridWithHistory(sets, repMax: null).isReadyToProgress, isFalse);
    expect(
      gridWithHistory(sets, previousPlannedSets: 0).isReadyToProgress,
      isFalse,
    );
  });

  test('last-session summary groups equal weights and preserves reps', () {
    final row = gridWithHistory([
      loggedSet(1),
      loggedSet(2),
      loggedSet(3, reps: 9),
      loggedSet(4, reps: 9),
    ]);
    expect(row.previousSummary, 'Last: 70 lb × 10, 10, 9, 9');
  });

  test('summary preserves changing loads units and unilateral sides', () {
    final row = gridWithHistory([
      loggedSet(1, left: 10, right: 9),
      loggedSet(2, weight: 65.5, left: 8, right: 8),
      loggedSet(
        3,
        weight: 30,
        left: 8,
        right: 7,
      ).copyWith(weightUnit: WeightUnit.kg),
    ], unilateral: true);
    expect(
      row.previousSummary,
      'Last: 70 lb × L10/R9; 65.5 lb × L8/R8; 30 kg × L8/R7',
    );
    expect(gridWithHistory([]).previousSummary, isNull);
    expect(
      gridWithHistory([loggedSet(1, weight: null)]).previousSummary,
      'Last: 10',
    );
  });

  test(
    'prefill uses corresponding historical set then the last working set',
    () {
      final row = gridWithHistory([loggedSet(1), loggedSet(2, weight: 65)]);
      expect(
        row.prefillWeightFor(
          loggedSet(1, weight: null, status: SetStatus.pending),
        ),
        70,
      );
      expect(
        row.prefillWeightFor(
          loggedSet(2, weight: null, status: SetStatus.pending),
        ),
        65,
      );
      expect(
        row.prefillWeightFor(
          loggedSet(3, weight: null, status: SetStatus.pending),
        ),
        65,
      );
    },
  );

  test(
    'prefill preserves existing input and carries forward current weight',
    () {
      final target = loggedSet(3, weight: null, status: SetStatus.pending);
      final row = gridWithHistory(
        [loggedSet(1), loggedSet(2, weight: 65)],
        currentSets: [loggedSet(2, weight: 80), loggedSet(1, weight: 75)],
      );
      expect(row.prefillWeightFor(target), 80);
      expect(
        row.prefillWeightFor(target.copyWith(weight: const Value(85))),
        85,
      );
      expect(gridWithHistory([]).prefillWeightFor(target), isNull);
    },
  );

  test('historical prefill converts weight to the current set unit', () {
    final target = loggedSet(
      1,
      weight: null,
      status: SetStatus.pending,
    ).copyWith(weightUnit: WeightUnit.kg);
    expect(gridWithHistory([loggedSet(1)]).prefillWeightFor(target), 31.75);
  });
}
