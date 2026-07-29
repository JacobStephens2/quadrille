import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
import 'package:countdown_ring/countdown_ring.dart';
import '../../../core/domain/exercise_order.dart';
import '../../../core/domain/rep_target.dart';
import '../../session/session_providers.dart';
import '../template_providers.dart';
import 'template_exercise_editor.dart';

/// Shows one template's planned grid and lets the user edit its rows — the
/// screen where a paper sheet gets recreated.
class TemplateDetailScreen extends ConsumerWidget {
  const TemplateDetailScreen({super.key, required this.templateId});

  final String templateId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final template = ref.watch(templateProvider(templateId));
    final rows = ref.watch(templateExercisesProvider(templateId));

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
                : IconButton(
                    icon: const Icon(Icons.play_circle_fill),
                    tooltip: 'Start workout',
                    onPressed: () => _start(context, ref),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(context, ref, v, template.value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              PopupMenuItem(value: 'archive', child: Text('Archive')),
            ],
          ),
        ],
      ),
      floatingActionButton: rows.maybeWhen(
        data: (list) => FloatingActionButton.extended(
          onPressed: () => showTemplateExerciseEditor(
            context,
            templateId: templateId,
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
              final endsGroup = i + 1 < list.length &&
                  list[i].supersetGroup != list[i + 1].supersetGroup;
              return Divider(height: 1, thickness: endsGroup ? 1 : 0.4);
            },
            itemBuilder: (context, i) => _RowTile(
              row: list[i],
              templateId: templateId,
            ),
          );
        },
      ),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final id =
        await ref.read(sessionRepositoryProvider).startFromTemplate(templateId);
    if (context.mounted) context.go('/session/$id');
  }

  /// Suggests the next bare order number (max group + 1).
  String _nextOrderLabel(List<TemplateExercise> rows) {
    if (rows.isEmpty) return '1';
    final maxGroup = rows
        .map((r) => ExerciseOrder.parse(r.orderLabel).groupNumber)
        .fold(0, (a, b) => a > b ? a : b);
    return '${maxGroup + 1}';
  }

  Future<void> _onMenu(
    BuildContext context,
    WidgetRef ref,
    String action,
    WorkoutTemplate? template,
  ) async {
    if (template == null) return;
    final repo = ref.read(templateRepositoryProvider);
    switch (action) {
      case 'rename':
        final name = await _promptText(context, 'Rename template', template.name);
        if (name != null && name.trim().isNotEmpty) {
          await repo.updateTemplate(template.id, name: name.trim());
        }
      case 'duplicate':
        final id = await repo.duplicateTemplate(
          template.id,
          newName: '${template.name} (copy)',
        );
        if (context.mounted) context.go('/templates/$id');
      case 'archive':
        await repo.archiveTemplate(template.id);
        if (context.mounted) context.go('/templates');
    }
  }
}

Future<String?> _promptText(
  BuildContext context,
  String title,
  String initial,
) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class _RowTile extends ConsumerWidget {
  const _RowTile({required this.row, required this.templateId});

  final TemplateExercise row;
  final String templateId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      confirmDismiss: (_) async => await _confirmDelete(context),
      onDismissed: (_) =>
          ref.read(templateRepositoryProvider).deleteExercise(row.id),
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
          child: Text(
            row.orderLabel,
            style: theme.textTheme.labelMedium,
          ),
        ),
        title: Text(row.displayName),
        subtitle: Text(
          [spec, if (row.notes != null) row.notes!].join('\n'),
        ),
        isThreeLine: row.notes != null,
        onTap: () => showTemplateExerciseEditor(
          context,
          templateId: templateId,
          existing: row,
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete row?'),
        content: Text('Remove "${row.displayName}" from this template?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
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
            Icon(Icons.playlist_add,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No exercises in this template',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Add rows like 1, 2A, 2B to recreate your sheet.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
