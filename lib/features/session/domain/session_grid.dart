import 'package:flutter/foundation.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/rep_target.dart';
import 'previous_session_exercise.dart';

/// One exercise row in a Session grid: the snapshot plus its ordered
/// set entries, with an optional reference to the last completed exercise.
@immutable
class SessionGridRow {
  const SessionGridRow({
    required this.exercise,
    required this.sets,
    this.previous,
  });

  final SessionExercise exercise;
  final List<SetEntry> sets;
  final PreviousSessionExercise? previous;

  List<SetEntry> get previousSets => previous?.sets ?? const [];
  String? get previousSummary => previous?.summary;

  bool get isDurationBased =>
      exercise.loadKind == LoadKind.timeOnly ||
      (exercise.durationMinSeconds != null && exercise.repMin == null);

  /// Preserve entered seconds; otherwise carry forward the latest completed
  /// earlier hold, falling back to the planned duration.
  int? prefillSecondsFor(SetEntry set) {
    if (set.reps != null) return set.reps;
    final earlier =
        sets
            .where(
              (s) =>
                  s.setNumber < set.setNumber &&
                  s.status == SetStatus.completed &&
                  s.deletedAt == null &&
                  s.reps != null,
            )
            .toList()
          ..sort((a, b) => a.setNumber.compareTo(b.setNumber));
    return earlier.lastOrNull?.reps ?? exercise.durationMinSeconds;
  }

  /// Existing input wins, then the latest earlier current set, then the same
  /// historical set number (or its last completed working set).
  double? prefillWeightFor(SetEntry set) {
    if (set.weight != null) return set.weight;
    final earlier =
        sets
            .where(
              (s) =>
                  s.setNumber < set.setNumber &&
                  s.weight != null &&
                  s.deletedAt == null,
            )
            .toList()
          ..sort((a, b) => a.setNumber.compareTo(b.setNumber));
    final reference =
        earlier.lastOrNull ??
        previousSets.where((s) => s.setNumber == set.setNumber).firstOrNull ??
        previousSets.lastOrNull;
    final weight = reference?.weight;
    if (weight == null || reference == null) return null;
    if (reference.weightUnit == set.weightUnit ||
        exercise.loadKind == LoadKind.machineSetting) {
      return weight;
    }
    final converted = reference.weightUnit == WeightUnit.lb
        ? weight * 0.45359237
        : weight / 0.45359237;
    return double.parse(converted.toStringAsFixed(2));
  }

  /// Every planned working set from the historical snapshot must reach the
  /// current rep ceiling. Bonus sets cannot replace missing planned sets.
  bool get isReadyToProgress {
    final maximum = exercise.repMax;
    final planned = previous?.exercise.plannedSets ?? 0;
    if (maximum == null || planned <= 0) return false;
    for (var number = 1; number <= planned; number++) {
      final set = previousSets
          .where((set) => set.setNumber == number)
          .firstOrNull;
      if (set == null ||
          set.deletedAt != null ||
          set.status != SetStatus.completed ||
          set.completedAt == null) {
        return false;
      }
      if (exercise.isUnilateral) {
        if ((set.leftReps ?? 0) < maximum || (set.rightReps ?? 0) < maximum) {
          return false;
        }
      } else if ((set.reps ?? 0) < maximum) {
        return false;
      }
    }
    return true;
  }

  RepTarget get target => RepTarget(
    repMin: exercise.repMin,
    repMax: exercise.repMax,
    durationMin: exercise.durationMinSeconds == null
        ? null
        : Duration(seconds: exercise.durationMinSeconds!),
    durationMax: exercise.durationMaxSeconds == null
        ? null
        : Duration(seconds: exercise.durationMaxSeconds!),
  );

  Duration get rest => Duration(seconds: exercise.plannedRestSeconds);

  /// Sets logged (completed) out of the total rows present.
  int get completedCount => sets.where((s) => s.completedAt != null).length;
  int get totalCount => sets.length;
  bool get isDone => totalCount > 0 && completedCount == totalCount;
}

/// The exercise and pending cell recommended after a logged set.
@immutable
class SessionSetRecommendation {
  const SessionSetRecommendation({required this.exercise, required this.set});

  final SessionExercise exercise;
  final SetEntry set;

  String get label =>
      '${exercise.orderLabel} · ${exercise.displayName} (Set ${set.setNumber})';
}

int _compareRoundPosition(
  SessionSetRecommendation a,
  SessionSetRecommendation b,
) {
  final round = a.set.setNumber.compareTo(b.set.setNumber);
  return round != 0
      ? round
      : a.exercise.sortIndex.compareTo(b.exercise.sortIndex);
}

/// Resolves the next pending cell after [after], or the most recently completed
/// cell on resume. Supersets rotate within a round before advancing rounds;
/// straight sets stay on their exercise. Exhausted blocks advance in sheet order.
SessionSetRecommendation? nextPendingSessionSet(
  List<SessionGridRow> rows, {
  SetEntry? after,
}) {
  final ordered = rows.where((row) => row.exercise.deletedAt == null).toList()
    ..sort((a, b) => a.exercise.sortIndex.compareTo(b.exercise.sortIndex));
  final completed =
      [
        for (final row in ordered)
          for (final set in row.sets)
            if (set.status == SetStatus.completed &&
                set.completedAt != null &&
                set.deletedAt == null)
              SessionSetRecommendation(exercise: row.exercise, set: set),
      ]..sort((a, b) {
        final time = a.set.completedAt!.compareTo(b.set.completedAt!);
        if (time != 0) return time;
        // Tied timestamps cannot recover action order on resume. Start from
        // the earlier round so pending holes are not bypassed. The live
        // session passes its exact last logged set as [after].
        return _compareRoundPosition(b, a);
      });
  final anchor = after ?? completed.lastOrNull?.set;
  final pending =
      <SessionSetRecommendation>[
        for (final row in ordered)
          for (final set in row.sets)
            if (set.status == SetStatus.pending &&
                set.completedAt == null &&
                set.deletedAt == null &&
                set.id != anchor?.id)
              SessionSetRecommendation(exercise: row.exercise, set: set),
      ]..sort((a, b) {
        final exercise = a.exercise.sortIndex.compareTo(b.exercise.sortIndex);
        return exercise != 0
            ? exercise
            : a.set.setNumber.compareTo(b.set.setNumber);
      });
  if (anchor == null) return pending.firstOrNull;
  final current = ordered
      .where((row) => row.exercise.id == anchor.sessionExerciseId)
      .firstOrNull;
  if (current == null) return pending.firstOrNull;

  final group = current.exercise.supersetGroup;
  final block = ordered
      .where(
        (row) => group == null
            ? row.exercise.id == current.exercise.id
            : row.exercise.supersetGroup == group,
      )
      .toList();
  final blockIds = block.map((row) => row.exercise.id).toSet();
  final inBlock =
      pending.where((next) => blockIds.contains(next.exercise.id)).toList()
        ..sort(_compareRoundPosition);
  if (inBlock.isNotEmpty) {
    if (group == null) return inBlock.first;
    final thisRound = inBlock.where(
      (next) => next.set.setNumber == anchor.setNumber,
    );
    return thisRound
            .where(
              (next) => next.exercise.sortIndex > current.exercise.sortIndex,
            )
            .firstOrNull ??
        thisRound.firstOrNull ??
        inBlock
            .where((next) => next.set.setNumber > anchor.setNumber)
            .firstOrNull ??
        inBlock.first;
  }
  return pending
      .where((next) => next.exercise.sortIndex > block.last.exercise.sortIndex)
      .firstOrNull;
}
