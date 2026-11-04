import 'package:flutter/foundation.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/rep_target.dart';

/// One exercise row in the active-session grid: the snapshot plus its ordered
/// set entries. A UI-friendly shape assembled from two streams.
@immutable
class SessionGridRow {
  const SessionGridRow({required this.exercise, required this.sets});

  final SessionExercise exercise;
  final List<SetEntry> sets;

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
  int get completedCount =>
      sets.where((s) => s.completedAt != null).length;
  int get totalCount => sets.length;
  bool get isDone => totalCount > 0 && completedCount == totalCount;
}

/// Groups flat set rows under their exercises, preserving exercise order.
List<SessionGridRow> buildGrid(
  List<SessionExercise> exercises,
  List<SetEntry> sets,
) {
  final byExercise = <String, List<SetEntry>>{};
  for (final s in sets) {
    (byExercise[s.sessionExerciseId] ??= []).add(s);
  }
  return [
    for (final e in exercises)
      SessionGridRow(
        exercise: e,
        sets: (byExercise[e.id] ?? [])
          ..sort((a, b) => a.setNumber.compareTo(b.setNumber)),
      ),
  ];
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
        // SQLite timestamps can tie within a second. Prefer the later round,
        // then the later exercise in that round.
        final round = a.set.setNumber.compareTo(b.set.setNumber);
        return round != 0
            ? round
            : a.exercise.sortIndex.compareTo(b.exercise.sortIndex);
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
        ..sort((a, b) {
          final round = a.set.setNumber.compareTo(b.set.setNumber);
          return round != 0
              ? round
              : a.exercise.sortIndex.compareTo(b.exercise.sortIndex);
        });
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
