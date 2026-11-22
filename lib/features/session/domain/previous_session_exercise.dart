import 'package:flutter/foundation.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/formatting/compact_number.dart';
import 'reps_in_reserve.dart';

/// The historical snapshot and its completed working sets, in set order.
@immutable
class PreviousSessionExercise {
  const PreviousSessionExercise({required this.exercise, required this.sets});

  final SessionExercise exercise;
  final List<SetEntry> sets;

  /// Consecutive sets at the same load share a compact weight prefix.
  String? get summary {
    if (sets.isEmpty) return null;
    final groups = <String>[];
    double? lastWeight;
    WeightUnit? lastUnit;
    for (final set in sets) {
      final reps = exercise.isUnilateral
          ? 'L${set.leftReps ?? '–'}/R${set.rightReps ?? '–'}'
          : '${set.reps ?? '–'}';
      final rpe = set.rpe;
      final setLabel = rpe == null
          ? reps
          : '$reps ${RepsInReserve.notationForRpe(rpe)}';
      final weight = exercise.loadKind.tracksWeight ? set.weight : null;
      if (groups.isNotEmpty &&
          weight == lastWeight &&
          set.weightUnit == lastUnit) {
        groups[groups.length - 1] += ', $setLabel';
      } else {
        final prefix = weight == null
            ? ''
            : '${compactNumber(weight)} ${set.weightUnit.label} × ';
        groups.add('$prefix$setLabel');
      }
      lastWeight = weight;
      lastUnit = set.weightUnit;
    }
    return 'Last: ${groups.join('; ')}';
  }
}
