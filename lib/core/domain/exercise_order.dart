import 'package:flutter/foundation.dart';

/// Parses and formats the order labels used on the paper sheets: `1`, `2A`,
/// `2B`, `3A`, `3B`, `4`, etc.
///
/// The numeric part ([groupNumber]) plus an optional letter [variant] together
/// drive superset grouping: rows that share a group number (`2A`, `2B`) are a
/// superset and the UI rests only after the last movement in the group.
@immutable
class ExerciseOrder implements Comparable<ExerciseOrder> {
  const ExerciseOrder({required this.groupNumber, this.variant});

  /// Parses a label like `2A`. Falls back to group 0 for unparseable input so
  /// a bad label never throws during data import.
  factory ExerciseOrder.parse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return const ExerciseOrder(groupNumber: 0);
    return ExerciseOrder(
      groupNumber: int.parse(match.group(1)!),
      variant: match.group(2)?.isEmpty ?? true
          ? null
          : match.group(2)!.toUpperCase(),
    );
  }

  static final RegExp _pattern = RegExp(r'^(\d+)\s*([A-Za-z]?)$');

  final int groupNumber;
  final String? variant;

  /// True when this row participates in a superset (has a letter variant).
  bool get isSupersetMember => variant != null;

  /// The grouping key shared by superset partners (`"2"` for `2A`/`2B`).
  String get groupKey => '$groupNumber';

  /// Canonical label, e.g. `2A` or `4`.
  String get label => '$groupNumber${variant ?? ''}';

  /// A monotonic sort index so rows order `1, 2A, 2B, 3, ...` naturally.
  /// Group number dominates; variant breaks ties (A < B < ...); a bare number
  /// (no variant) sorts before any lettered variant in the same group.
  int get sortIndex {
    final variantRank = variant == null ? 0 : variant!.codeUnitAt(0) - 64;
    return groupNumber * 100 + variantRank;
  }

  @override
  int compareTo(ExerciseOrder other) => sortIndex.compareTo(other.sortIndex);

  @override
  bool operator ==(Object other) =>
      other is ExerciseOrder &&
      other.groupNumber == groupNumber &&
      other.variant == variant;

  @override
  int get hashCode => Object.hash(groupNumber, variant);

  @override
  String toString() => 'ExerciseOrder($label)';
}
