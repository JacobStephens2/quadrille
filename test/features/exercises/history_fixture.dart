import 'dart:async';

import 'package:drift/drift.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/exercises/domain/exercise_history.dart';

/// Real SQLite rows with explicit identifiers and dates for ordering tests.
class HistoryFixture {
  HistoryFixture(this.db);

  final QuadrilleDatabase db;
  static final date = DateTime(2026, 1, 5, 12);

  Future<void> session(
    String id, {
    DateTime? startedAt,
    SessionStatus status = SessionStatus.completed,
    DateTime? deletedAt,
  }) => db
      .into(db.workoutSessions)
      .insert(
        WorkoutSessionsCompanion.insert(
          id: id,
          name: 'Push $id',
          status: Value(status),
          startedAt: startedAt ?? date,
          // Completion is determined by status, not the session timestamp.
          deletedAt: Value(deletedAt),
          createdAt: date,
          updatedAt: date,
        ),
      );

  Future<void> exercise(
    String id,
    String sessionId, {
    String name = 'Bench Press',
    int sortIndex = 1,
    String? sourceId,
    DateTime? deletedAt,
  }) => db
      .into(db.sessionExercises)
      .insert(
        SessionExercisesCompanion.insert(
          id: id,
          sessionId: sessionId,
          displayName: name,
          sourceTemplateExerciseId: Value(sourceId),
          orderLabel: '1',
          sortIndex: sortIndex,
          deletedAt: Value(deletedAt),
          createdAt: date,
          updatedAt: date,
        ),
      );

  Future<void> set(
    String id,
    String exerciseId, {
    int number = 1,
    double? weight = 100,
    int? reps = 10,
    SetStatus status = SetStatus.completed,
    bool timestamp = true,
    DateTime? deletedAt,
  }) => db
      .into(db.setEntries)
      .insert(
        SetEntriesCompanion.insert(
          id: id,
          sessionExerciseId: exerciseId,
          setNumber: number,
          weight: Value(weight),
          reps: Value(reps),
          status: Value(status),
          completedAt: Value(timestamp ? date : null),
          deletedAt: Value(deletedAt),
          createdAt: date,
          updatedAt: date,
        ),
      );

  Future<void> workout(
    String id, {
    SessionStatus status = SessionStatus.completed,
    DateTime? startedAt,
  }) async {
    await session(id, status: status, startedAt: startedAt);
    await exercise('$id-exercise', id);
    await set('$id-set', '$id-exercise');
  }
}

/// Records every complete result so transaction tests can reject mixtures.
class HistoryObservation {
  HistoryObservation(Stream<ExerciseHistory> stream) {
    _subscription = stream.listen((history) {
      snapshots.add(history);
      _events.add(history);
    }, onError: _events.addError);
  }

  final snapshots = <ExerciseHistory>[];
  final _events = StreamController<ExerciseHistory>.broadcast(sync: true);
  late final StreamSubscription<ExerciseHistory> _subscription;

  Future<ExerciseHistory> until(
    bool Function(ExerciseHistory) predicate, {
    int after = 0,
  }) async {
    for (final history in snapshots.skip(after).toList().reversed) {
      if (predicate(history)) return history;
    }
    return _events.stream
        .firstWhere(predicate)
        .timeout(const Duration(seconds: 3));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _events.close();
  }
}

/// Delay or fail real SQL reads at the existing executor boundary.
class HistoryReadControl extends QueryInterceptor {
  Object? failure;
  bool delay = false;
  final started = Completer<void>();
  final release = Completer<void>();
  final returned = Completer<void>();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (failure != null) throw failure!;
    final rows = await executor.runSelect(statement, args);
    if (delay) {
      if (!started.isCompleted) started.complete();
      await release.future;
      if (!returned.isCompleted) returned.complete();
    }
    return rows;
  }
}
