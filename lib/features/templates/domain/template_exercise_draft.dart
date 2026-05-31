import '../../../core/domain/enums.dart';
import '../../../core/domain/exercise_order.dart';
import '../../../core/domain/rep_target.dart';

/// A write-model for adding or editing a row in a template, decoupling the UI
/// from the Drift companion shape. The `orderLabel` (e.g. `2A`) is parsed into
/// an [ExerciseOrder] to derive the sort index and superset grouping.
class TemplateExerciseDraft {
  TemplateExerciseDraft({
    required this.displayName,
    required this.orderLabel,
    this.exerciseId,
    this.targetSets = 3,
    this.repTarget = RepTarget.none,
    this.restSeconds = 120,
    this.notes,
    this.isUnilateral = false,
    this.loadKind = LoadKind.externalWeight,
  });

  final String displayName;
  final String orderLabel;
  final String? exerciseId;
  final int targetSets;
  final RepTarget repTarget;
  final int restSeconds;
  final String? notes;
  final bool isUnilateral;
  final LoadKind loadKind;

  ExerciseOrder get order => ExerciseOrder.parse(orderLabel);

  /// Sort index derived from the parsed order so rows fall in `1, 2A, 2B` order.
  int get sortIndex => order.sortIndex;

  /// Shared key for superset partners (`2` for `2A`/`2B`); null when solo.
  String? get supersetGroup => order.isSupersetMember ? order.groupKey : null;
}
