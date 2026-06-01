import 'package:flutter/foundation.dart';

import '../../../core/database/database.dart';
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
