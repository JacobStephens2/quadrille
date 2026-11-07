import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/timer/timer_providers.dart';

final _date = DateTime(2026, 11, 6, 12);

SessionGridRow _row(String id, List<SetEntry> sets) => SessionGridRow(
  exercise: SessionExercise(
    id: id,
    sessionId: 'session',
    displayName: id,
    orderLabel: id,
    sortIndex: 0,
    plannedSets: 3,
    plannedRestSeconds: 90,
    isUnilateral: false,
    loadKind: LoadKind.externalWeight,
    createdAt: _date,
    updatedAt: _date,
  ),
  sets: sets,
);

SetEntry _set(
  String exercise,
  int number,
  DateTime? completedAt, {
  SetStatus status = SetStatus.completed,
  DateTime? deletedAt,
}) => SetEntry(
  id: '$exercise-$number',
  sessionExerciseId: exercise,
  setNumber: number,
  weightUnit: WeightUnit.lb,
  status: status,
  completedAt: completedAt,
  deletedAt: deletedAt,
  createdAt: _date,
  updatedAt: _date,
);

void main() {
  testWidgets('paired exercises keep independent wall-clock rest countdowns', (
    tester,
  ) async {
    var now = _date.add(const Duration(seconds: 30));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [restTimerNowProvider.overrideWithValue(() => now)],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SessionExerciseCard(row: _row('1A', [_set('1A', 1, _date)])),
                SessionExerciseCard(
                  row: _row('1B', [
                    _set('1B', 1, _date.add(const Duration(seconds: 15))),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Rest 01:00'), findsOneWidget);
    expect(find.text('00:30 since last set'), findsOneWidget);
    expect(find.text('Rest 01:15'), findsOneWidget);
    expect(find.text('00:15 since last set'), findsOneWidget);

    now = now.add(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('Rest 00:50'), findsOneWidget);
    expect(find.text('Rest 01:05'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rest uses the latest live completion rather than set order', (
    tester,
  ) async {
    final row = _row('1A', [
      _set('1A', 1, _date.add(const Duration(seconds: 20))),
      _set('1A', 2, _date),
      _set(
        '1A',
        3,
        _date.add(const Duration(seconds: 25)),
        status: SetStatus.skipped,
      ),
      _set('1A', 4, _date.add(const Duration(seconds: 26)), deletedAt: _date),
      _set(
        '1A',
        5,
        _date.add(const Duration(seconds: 27)),
        status: SetStatus.pending,
      ),
      _set('1A', 6, null),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          restTimerNowProvider.overrideWithValue(
            () => _date.add(const Duration(seconds: 30)),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: SessionExerciseCard(row: row)),
        ),
      ),
    );
    expect(find.text('Rest 01:20'), findsOneWidget);
    expect(find.text('00:10 since last set'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rest expires, resets on a new set and survives remounting', (
    tester,
  ) async {
    var now = _date.add(const Duration(milliseconds: 89500));
    var row = _row('1A', [_set('1A', 1, _date)]);
    Widget screen() => ProviderScope(
      overrides: [restTimerNowProvider.overrideWithValue(() => now)],
      child: MaterialApp(
        home: Scaffold(body: SessionExerciseCard(row: row)),
      ),
    );
    await tester.pumpWidget(screen());
    expect(find.text('Rest 00:01'), findsOneWidget);

    now = _date.add(const Duration(seconds: 90));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('Rest complete'), findsOneWidget);
    expect(find.text('01:30 since last set'), findsOneWidget);

    row = _row('1A', [_set('1A', 1, _date), _set('1A', 2, now)]);
    await tester.pumpWidget(screen());
    expect(find.text('Rest 01:30'), findsOneWidget);
    expect(find.text('00:00 since last set'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    now = _date.add(const Duration(minutes: 10));
    await tester.pumpWidget(screen());
    expect(find.text('Rest complete'), findsOneWidget);
    expect(find.text('08:30 since last set'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('history and exercises without live completions have no timer', (
    tester,
  ) async {
    for (final (readOnly, sets) in [
      (true, [_set('1A', 1, _date)]),
      (false, <SetEntry>[]),
      (false, [_set('1A', 1, null, status: SetStatus.pending)]),
      (false, [_set('1A', 1, _date, status: SetStatus.skipped)]),
      (false, [_set('1A', 1, _date, deletedAt: _date)]),
      (false, [_set('1A', 1, null)]),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SessionExerciseCard(
                row: _row('1A', sets),
                readOnly: readOnly,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('since last set'), findsNothing);
      expect(find.textContaining('Rest '), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
