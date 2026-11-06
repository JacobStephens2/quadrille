import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import 'package:countdown_ring/countdown_ring.dart';
import '../../../core/domain/enums.dart';
import '../../../core/formatting/compact_number.dart';
import '../../timer/timer_providers.dart';
import '../domain/reps_in_reserve.dart';
import '../domain/session_grid.dart';
import 'previous_session_reference.dart';

/// One exercise within a session: header (order, name, target, rest, notes,
/// progress) and a wrap of tappable set cells. Used live (editable) and in
/// history ([readOnly]).
class SessionExerciseCard extends StatelessWidget {
  const SessionExerciseCard({
    super.key,
    required this.row,
    this.readOnly = false,
    this.nextSetId,
    this.onTapSet,
    this.onAddSet,
    this.onStartRest,
  });

  final SessionGridRow row;
  final bool readOnly;
  final String? nextSetId;
  final void Function(SetEntry set)? onTapSet;
  final VoidCallback? onAddSet;
  final VoidCallback? onStartRest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = row.exercise;
    final spec = [
      if (!row.target.isEmpty) row.target.label,
      'rest ${row.rest.compactLabel}',
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
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (!readOnly && onStartRest != null)
                  IconButton(
                    tooltip: 'Start rest (${row.rest.compactLabel})',
                    icon: const Icon(Icons.timer_outlined),
                    onPressed: onStartRest,
                  ),
              ],
            ),
            if (!readOnly && row.lastCompletedAt != null)
              _ExerciseRestTimer(
                completedAt: row.lastCompletedAt!,
                rest: row.rest,
              ),
            if (!readOnly) PreviousSessionReference(row: row),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final set in row.sets)
                  _SetCell(
                    set: set,
                    isNext:
                        !readOnly &&
                        set.status == SetStatus.pending &&
                        set.id == nextSetId,
                    unilateral: e.isUnilateral,
                    durationBased: row.isDurationBased,
                    showWeight: e.loadKind.tracksWeight,
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

/// A display derived from saved sets, independent of the single alert timer.
class _ExerciseRestTimer extends ConsumerWidget {
  const _ExerciseRestTimer({required this.completedAt, required this.rest});

  final DateTime completedAt;
  final Duration rest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(timerTickProvider);
    final sinceLastSet = ref
        .watch(restTimerNowProvider)()
        .difference(completedAt);
    final elapsed = sinceLastSet.isNegative ? Duration.zero : sinceLastSet;
    final remaining = rest - elapsed;
    final done = remaining <= Duration.zero;
    final countdown = Duration(
      seconds: (remaining.inMicroseconds / Duration.microsecondsPerSecond)
          .ceil(),
    );
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle_outline : Icons.timer_outlined,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              spacing: 8,
              children: [
                Text(
                  done ? 'Rest complete' : 'Rest ${countdown.clockLabel}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                Text(
                  '${elapsed.clockLabel} since last set',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetCell extends StatelessWidget {
  const _SetCell({
    required this.set,
    required this.unilateral,
    required this.durationBased,
    required this.showWeight,
    required this.unit,
    this.isNext = false,
    this.onTap,
  });

  final SetEntry set;
  final bool unilateral;
  final bool durationBased;
  final bool showWeight;
  final WeightUnit unit;
  final bool isNext;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final completed = set.status == SetStatus.completed;
    final skipped = set.status == SetStatus.skipped;

    final (bg, fg, border) = switch (set.status) {
      SetStatus.completed => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        scheme.primary,
      ),
      SetStatus.skipped => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        scheme.outlineVariant,
      ),
      _ =>
        isNext
            ? (
                scheme.secondaryContainer,
                scheme.onSecondaryContainer,
                scheme.secondary,
              )
            : (scheme.surface, scheme.onSurfaceVariant, scheme.outlineVariant),
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
            if (isNext)
              Text(
                'Next',
                style: theme.textTheme.labelSmall?.copyWith(color: fg),
              ),
            Text(
              'Set ${set.setNumber}',
              style: theme.textTheme.labelSmall?.copyWith(color: fg),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _resultLabel() {
    final quantity = durationBased
        ? '${set.reps ?? '–'}s'
        : unilateral
        ? '${set.leftReps ?? '–'}/${set.rightReps ?? '–'}'
        : '${set.reps ?? '–'}';
    return [
      if (showWeight && set.weight != null) '${compactNumber(set.weight!)} ×',
      quantity,
      if (set.rpe != null)
        '@${RepsInReserve.fromRpe(set.rpe!)?.label ?? compactNumber(10 - set.rpe!)}',
      if (set.partials != null) '+${set.partials}p',
    ].join(' ');
  }
}
