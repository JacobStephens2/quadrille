import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import 'package:countdown_ring/countdown_ring.dart';
import '../../../core/domain/exercise_order.dart';
import '../../../core/domain/rep_target.dart';
import '../../session/presentation/start_workout.dart';
import '../../session/session_starting.dart';
import '../template_providers.dart';
import '../template_exercise_editing.dart';
import '../template_management.dart';
import 'template_exercise_editor.dart';
import 'template_management_actions.dart';

/// Shows one template's planned grid and lets the user edit its rows — the
/// screen where a paper sheet gets recreated.
class TemplateDetailScreen extends ConsumerWidget {
  const TemplateDetailScreen({super.key, required this.templateId});

  final String templateId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final template = ref.watch(templateProvider(templateId));
    final rows = ref.watch(templateExercisesProvider(templateId));
    final editing = ref.watch(templateExerciseEditingProvider);
    final management = ref.watch(templateManagementProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/templates'),
        ),
        title: Text(template.value?.name ?? 'Template'),
        actions: [
          rows.maybeWhen(
            data: (list) => list.isEmpty
                ? const SizedBox.shrink()
                : _StartWorkoutAction(
                    templateId: templateId,
                    onStart: (starting) => startWorkout(context, starting),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          if (template.value case final value?)
            TemplateManagementMenu(
              management: management,
              templateId: value.id,
              name: value.name,
            ),
        ],
      ),
      floatingActionButton: rows.maybeWhen(
        data: (list) => FloatingActionButton.extended(
          onPressed: () => showTemplateExerciseEditor(
            context,
            opening: editing.edit(templateId),
            suggestedOrderLabel: _nextOrderLabel(list),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Row'),
        ),
        orElse: () => null,
      ),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyRows();
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: list.length,
            separatorBuilder: (context, i) {
              // Visually break between superset groups.
              final endsGroup =
                  i + 1 < list.length &&
                  list[i].supersetGroup != list[i + 1].supersetGroup;
              return Divider(height: 1, thickness: endsGroup ? 1 : 0.4);
            },
            itemBuilder: (context, i) => _RowTile(
              row: list[i],
              templateId: templateId,
              editing: editing,
            ),
          );
        },
      ),
    );
  }

  /// Suggests the next bare order number (max group + 1).
  String _nextOrderLabel(List<TemplateExercise> rows) {
    if (rows.isEmpty) return '1';
    final maxGroup = rows
        .map((r) => ExerciseOrder.parse(r.orderLabel).groupNumber)
        .fold(0, (a, b) => a > b ? a : b);
    return '${maxGroup + 1}';
  }
}

class _StartWorkoutAction extends ConsumerWidget {
  const _StartWorkoutAction({required this.templateId, required this.onStart});

  final String templateId;
  final ValueChanged<SessionStartingHandle> onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starting = ref.watch(sessionStartingProvider(templateId));
    return ListenableBuilder(
      listenable: starting,
      builder: (context, _) => IconButton(
        icon: starting.isPending
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: 'Starting workout',
                ),
              )
            : const Icon(Icons.play_circle_fill),
        tooltip: 'Start workout',
        onPressed: starting.isPending || !starting.isCurrent
            ? null
            : () => onStart(starting),
      ),
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.row,
    required this.templateId,
    required this.editing,
  });

  final TemplateExercise row;
  final String templateId;
  final TemplateExerciseEditing editing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = RepTarget(
      repMin: row.repMin,
      repMax: row.repMax,
      durationMin: row.durationMinSeconds == null
          ? null
          : Duration(seconds: row.durationMinSeconds!),
      durationMax: row.durationMaxSeconds == null
          ? null
          : Duration(seconds: row.durationMaxSeconds!),
    );
    final spec = [
      '${row.targetSets} sets',
      if (!target.isEmpty) target.label,
      'rest ${Duration(seconds: row.restSeconds).compactLabel}',
    ].join(' · ');

    return Dismissible(
      key: ValueKey(row.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        await _confirmDelete(context, editing.deletion(templateId, row.id));
        return false;
      },
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete, color: theme.colorScheme.onErrorContainer),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: row.supersetGroup == null
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primaryContainer,
          child: Text(row.orderLabel, style: theme.textTheme.labelMedium),
        ),
        title: Text(row.displayName),
        subtitle: Text([spec, if (row.notes != null) row.notes!].join('\n')),
        isThreeLine: row.notes != null,
        onTap: () => showTemplateExerciseEditor(
          context,
          opening: editing.edit(templateId, rowId: row.id),
          existing: row,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    TemplateExerciseDeletionOpening opening,
  ) async {
    try {
      await showDialog<void>(
        context: context,
        builder: (_) =>
            _DeleteRowDialog(opening: opening, name: row.displayName),
      );
    } finally {
      opening.release();
    }
  }
}

class _DeleteRowDialog extends StatefulWidget {
  const _DeleteRowDialog({required this.opening, required this.name});

  final TemplateExerciseDeletionOpening opening;
  final String name;

  @override
  State<_DeleteRowDialog> createState() => _DeleteRowDialogState();
}

class _DeleteRowDialogState extends State<_DeleteRowDialog> {
  @override
  void dispose() {
    widget.opening.release();
    super.dispose();
  }

  Future<void> _delete() async {
    final result = await widget.opening.delete();
    if (result == TemplateExerciseEditingState.succeeded &&
        mounted &&
        widget.opening.isCurrent &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.opening,
    builder: (context, _) => AlertDialog(
      title: const Text('Delete row?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Remove "${widget.name}" from this template?'),
          if (widget.opening.state == TemplateExerciseEditingState.failed)
            const Text('Could not delete this row. Please try again.'),
          if (widget.opening.state == TemplateExerciseEditingState.superseded)
            const Text(
              'This confirmation is no longer current. Close and reopen it.',
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.opening.canSubmit ? _delete : null,
          child: const Text('Delete'),
        ),
      ],
    ),
  );
}

class _EmptyRows extends StatelessWidget {
  const _EmptyRows();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_add,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No exercises in this template',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Add rows like 1, 2A, 2B to recreate your sheet.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
