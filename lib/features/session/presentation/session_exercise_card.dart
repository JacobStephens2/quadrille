import 'package:flutter/material.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/duration_format.dart';
import '../../../core/domain/enums.dart';
import '../domain/session_grid.dart';

/// One exercise within a session: header (order, name, target, rest, notes,
/// progress) and a wrap of tappable set cells. Used live (editable) and in
/// history ([readOnly]).
class SessionExerciseCard extends StatelessWidget {
  const SessionExerciseCard({
    super.key,
    required this.row,
    this.readOnly = false,
    this.onTapSet,
    this.onAddSet,
    this.onStartRest,
  });

  final SessionGridRow row;
  final bool readOnly;
  final void Function(SetEntry set)? onTapSet;
  final VoidCallback? onAddSet;
  final VoidCallback? onStartRest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = row.exercise;
    final spec = [
      if (!row.target.isEmpty) row.target.label,
      'rest ${row.rest.restLabel}',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: e.supersetGroup == null
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.primaryContainer,
                  child: Text(e.orderLabel, style: theme.textTheme.labelMedium),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.displayName, style: theme.textTheme.titleMedium),
                      Text(spec, style: theme.textTheme.bodySmall),
                      if (e.plannedNotes != null)
                        Text(
                          e.plannedNotes!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (row.isDone)
                  Icon(Icons.check_circle, color: theme.colorScheme.primary)
                else
                  Text(
                    '${row.completedCount}/${row.totalCount}',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                if (!readOnly && onStartRest != null)
                  IconButton(
                    tooltip: 'Start rest (${row.rest.restLabel})',
                    icon: const Icon(Icons.timer_outlined),
                    onPressed: onStartRest,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final set in row.sets)
                  _SetCell(
                    set: set,
                    unilateral: e.isUnilateral,
                    showWeight: e.loadKind != LoadKind.bodyweight &&
                        e.loadKind != LoadKind.none,
                    unit: set.weightUnit,
                    onTap: readOnly ? null : () => onTapSet?.call(set),
                  ),
                if (!readOnly)
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Set'),
                    onPressed: onAddSet,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SetCell extends StatelessWidget {
  const _SetCell({
    required this.set,
    required this.unilateral,
    required this.showWeight,
    required this.unit,
    this.onTap,
  });

  final SetEntry set;
  final bool unilateral;
  final bool showWeight;
  final WeightUnit unit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final completed = set.status == SetStatus.completed;
    final skipped = set.status == SetStatus.skipped;

    final (bg, fg, border) = switch (set.status) {
      SetStatus.completed => (scheme.primaryContainer, scheme.onPrimaryContainer, scheme.primary),
      SetStatus.skipped => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, scheme.outlineVariant),
      _ => (scheme.surface, scheme.onSurfaceVariant, scheme.outlineVariant),
    };

    final label = skipped
        ? 'skip'
        : completed
            ? _resultLabel()
            : 'Set ${set.setNumber}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Set ${set.setNumber}',
                style: theme.textTheme.labelSmall?.copyWith(color: fg)),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  String _resultLabel() {
    final reps = unilateral
        ? '${set.leftReps ?? '–'}/${set.rightReps ?? '–'}'
        : '${set.reps ?? '–'}';
    if (showWeight && set.weight != null) {
      final w = set.weight! == set.weight!.roundToDouble()
          ? set.weight!.toInt().toString()
          : set.weight!.toString();
      return '$w × $reps';
    }
    return reps;
  }
}
