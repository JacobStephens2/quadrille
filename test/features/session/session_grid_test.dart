import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';

SessionGridRow row(
  String orderLabel,
  int sortIndex, {
  String? group,
  int count = 3,
  int completed = 0,
}) {
  final now = DateTime(2026);
  return SessionGridRow(
    exercise: SessionExercise(
      id: orderLabel,
      sessionId: 'session',
      displayName: orderLabel == '1B' ? 'Weighted Chin-Up' : 'Bench Press',
      orderLabel: orderLabel,
      sortIndex: sortIndex,
      supersetGroup: group,
      plannedSets: count,
      plannedRestSeconds: 90,
      isUnilateral: false,
      loadKind: LoadKind.externalWeight,
      createdAt: now,
      updatedAt: now,
    ),
    sets: [
      for (var n = 1; n <= count; n++)
        SetEntry(
          id: '$orderLabel-$n',
          sessionExerciseId: orderLabel,
          setNumber: n,
          weightUnit: WeightUnit.lb,
          status: n <= completed ? SetStatus.completed : SetStatus.pending,
          completedAt: n <= completed ? now.add(Duration(seconds: n)) : null,
          createdAt: now,
          updatedAt: now,
        ),
    ],
  );
}

void main() {
  test('1A set 1 recommends 1B set 1 in sortIndex order', () {
    final a = row('1A', 10, group: '1', completed: 1);
    final b = row('1B', 20, group: '1');

    final next = nextPendingSessionSet([b, a], after: a.sets.first);

    expect(next?.exercise.id, '1B');
    expect(next?.set.setNumber, 1);
    expect(next?.label, '1B · Weighted Chin-Up (Set 1)');
  });

  test('1B set 1 wraps to 1A set 2', () {
    final a = row('1A', 10, group: '1', completed: 1);
    final b = row('1B', 20, group: '1', completed: 1);
    final next = nextPendingSessionSet([a, b], after: b.sets.first);
    expect((next?.exercise.id, next?.set.setNumber), ('1A', 2));
  });

  test('unequal pair leaves the fourth set on 4A before the next block', () {
    final a = row('4A', 10, group: '4', count: 4, completed: 3);
    final b = row('4B', 20, group: '4', completed: 3);
    final c = row('5', 30);
    final next = nextPendingSessionSet([a, b, c], after: b.sets.last);
    expect((next?.exercise.id, next?.set.setNumber), ('4A', 4));
  });

  test('finished block advances to 2A set 1', () {
    final a = row('1A', 10, group: '1', completed: 3);
    final b = row('1B', 20, group: '1', completed: 3);
    final next = nextPendingSessionSet([
      a,
      b,
      row('2A', 30, group: '2'),
    ], after: b.sets.last);
    expect((next?.exercise.id, next?.set.setNumber), ('2A', 1));
    expect(nextPendingSessionSet([a, b], after: b.sets.last), isNull);
  });

  test('straight sets stay on the same exercise until complete', () {
    final a = row('1', 10, completed: 1);
    final b = row('2', 20);
    final next = nextPendingSessionSet([a, b], after: a.sets.first);
    expect((next?.exercise.id, next?.set.setNumber), ('1', 2));
    final done = row('1', 10, completed: 3);
    expect(
      nextPendingSessionSet([done, b], after: done.sets.last)?.exercise.id,
      '2',
    );
  });

  test('recommendation on resume follows the latest completed set', () {
    final a = row('1A', 10, group: '1', completed: 2);
    final b = row('1B', 20, group: '1', completed: 1);
    final next = nextPendingSessionSet([a, b]);
    expect((next?.exercise.id, next?.set.setNumber), ('1B', 2));
  });

  test('rotation supports three exercises in one superset', () {
    final a = row('1A', 10, group: '1', completed: 1);
    final b = row('1B', 20, group: '1', completed: 1);
    final c = row('1C', 30, group: '1');
    final next = nextPendingSessionSet([c, a, b], after: b.sets.first);
    expect((next?.exercise.id, next?.set.setNumber), ('1C', 1));
  });

  test('skipped and deleted cells are not recommended', () {
    final a = row('1A', 10, group: '1', completed: 1);
    final b = row('1B', 20, group: '1');
    final excluded = SessionGridRow(
      exercise: b.exercise,
      sets: [
        b.sets[0].copyWith(status: SetStatus.skipped),
        b.sets[1].copyWith(deletedAt: Value(DateTime(2026))),
        b.sets[2],
      ],
    );
    final next = nextPendingSessionSet([a, excluded], after: a.sets.first);
    expect((next?.exercise.id, next?.set.setNumber), ('1A', 2));
  });

  test('a stale snapshot excludes the just-logged cell', () {
    final a = row('1A', 10, group: '1');
    final b = row('1B', 20, group: '1');
    final next = nextPendingSessionSet([a, b], after: a.sets.first);
    expect((next?.exercise.id, next?.set.setNumber), ('1B', 1));
  });

  test('an empty or entirely completed session has no recommendation', () {
    expect(nextPendingSessionSet([]), isNull);
    expect(nextPendingSessionSet([row('1', 10, completed: 3)]), isNull);
  });
}
