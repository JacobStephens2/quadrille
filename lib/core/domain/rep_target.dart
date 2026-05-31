import 'package:flutter/foundation.dart';

/// A planned target for a set, mirroring the right-hand annotations on the
/// paper sheets: rep ranges like `6-8`, `8-12`, `12-20`, and timed targets
/// like `30-60s`.
///
/// Stored on the database as four nullable integer columns
/// (`repMin`, `repMax`, `durationMinSeconds`, `durationMaxSeconds`) so it can
/// express a rep range, a duration range, or both, without a polymorphic
/// schema. All-null means "no specific target".
@immutable
class RepTarget {
  const RepTarget({
    this.repMin,
    this.repMax,
    this.durationMin,
    this.durationMax,
  });

  /// A simple rep range, e.g. `RepTarget.reps(6, 8)`.
  factory RepTarget.reps(int min, int max) =>
      RepTarget(repMin: min, repMax: max);

  /// A single rep count, e.g. `RepTarget.fixedReps(5)`.
  factory RepTarget.fixedReps(int reps) =>
      RepTarget(repMin: reps, repMax: reps);

  /// A timed hold/carry range, e.g. `RepTarget.duration(30, 60)`.
  factory RepTarget.duration(int minSeconds, int maxSeconds) => RepTarget(
        durationMin: Duration(seconds: minSeconds),
        durationMax: Duration(seconds: maxSeconds),
      );

  static const RepTarget none = RepTarget();

  final int? repMin;
  final int? repMax;
  final Duration? durationMin;
  final Duration? durationMax;

  bool get hasReps => repMin != null || repMax != null;
  bool get hasDuration => durationMin != null || durationMax != null;
  bool get isEmpty => !hasReps && !hasDuration;

  /// Human label as it would read on the sheet: `6-8`, `12`, `30-60s`,
  /// or a combination. Returns an empty string when there is no target.
  String get label {
    final parts = <String>[];
    if (hasReps) parts.add(_rangeLabel(repMin, repMax));
    if (hasDuration) {
      parts.add('${_rangeLabel(
        durationMin?.inSeconds,
        durationMax?.inSeconds,
      )}s');
    }
    return parts.join(' · ');
  }

  static String _rangeLabel(int? min, int? max) {
    if (min != null && max != null) {
      return min == max ? '$min' : '$min-$max';
    }
    return '${min ?? max}';
  }

  @override
  bool operator ==(Object other) =>
      other is RepTarget &&
      other.repMin == repMin &&
      other.repMax == repMax &&
      other.durationMin == durationMin &&
      other.durationMax == durationMax;

  @override
  int get hashCode => Object.hash(repMin, repMax, durationMin, durationMax);

  @override
  String toString() => 'RepTarget(${label.isEmpty ? 'none' : label})';
}
