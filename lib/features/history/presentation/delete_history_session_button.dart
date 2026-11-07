import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../history_deletion.dart';

class DeleteHistorySessionButton extends ConsumerWidget {
  const DeleteHistorySessionButton({super.key, required this.session});

  final WorkoutSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delete = ref.watch(deleteHistorySessionProvider(session.id));
    return IconButton(
      tooltip: 'Delete workout',
      icon: const Icon(Icons.delete_outline),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) =>
            _DeleteHistorySessionDialog(session: session, onDelete: delete),
      ),
    );
  }
}

class _DeleteHistorySessionDialog extends ConsumerWidget {
  const _DeleteHistorySessionDialog({
    required this.session,
    required this.onDelete,
  });

  final WorkoutSession session;
  final DeleteHistorySession onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = historyDeletionControllerProvider(onDelete);
    final state = ref.watch(controller);
    ref.listen(controller, (_, next) {
      if (next.value == true) Navigator.of(context).pop();
    });
    final error = state.hasError
        ? 'Could not delete workout. Please try again.'
        : state.value == false
        ? 'This workout is unavailable or your local profile changed. '
              'Close and reopen History.'
        : null;
    return PopScope(
      canPop: !state.isLoading,
      child: AlertDialog(
        title: const Text('Delete workout?'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.name),
            Text(
              DateFormat(
                'EEE, MMM d, y · h:mm a',
              ).format(session.startedAt.toLocal()),
            ),
            const SizedBox(height: 16),
            const Text(
              'This removes the workout and its logged sets from history '
              'and exercise records. This cannot be undone.',
            ),
            if (error != null) ...[const SizedBox(height: 12), Text(error)],
          ],
        ),
        actions: [
          TextButton(
            onPressed: state.isLoading
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: state.isLoading || state.value == false
                ? null
                : () => ref.read(controller.notifier).delete(),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(state.isLoading ? 'Deleting…' : 'Delete'),
          ),
        ],
      ),
    );
  }
}
