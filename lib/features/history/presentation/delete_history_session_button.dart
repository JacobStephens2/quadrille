import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../shared/presentation/presentation_opening.dart';
import '../history_deletion.dart';

class DeleteHistorySessionButton extends ConsumerWidget {
  const DeleteHistorySessionButton({
    super.key,
    required this.session,
    required this.screenContext,
  });

  final WorkoutSession session;
  final BuildContext screenContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deletion = ref.watch(historyDeletionProvider);
    return IconButton(
      tooltip: 'Delete workout',
      icon: const Icon(Icons.delete_outline),
      onPressed: () async {
        final opening = deletion.open(session);
        final presentation = PresentationOpening.capture(screenContext);
        try {
          await showDialog<void>(
            context: screenContext,
            builder: (context) => _DeleteHistorySessionDialog(
              opening: opening,
              presentation: presentation.bindModal(context),
            ),
          );
        } finally {
          opening.release();
        }
      },
    );
  }
}

class _DeleteHistorySessionDialog extends StatefulWidget {
  const _DeleteHistorySessionDialog({
    required this.opening,
    required this.presentation,
  });

  final HistoryDeletionOpening opening;
  final PresentationOpening presentation;

  @override
  State<_DeleteHistorySessionDialog> createState() =>
      _DeleteHistorySessionDialogState();
}

class _DeleteHistorySessionDialogState
    extends State<_DeleteHistorySessionDialog> {
  bool _silent = false;

  @override
  void dispose() {
    widget.opening.release();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!widget.opening.canSubmit) return;
    setState(() => _silent = false);
    final result = await widget.opening.delete();
    if (!mounted) return;
    if (!widget.presentation.isCurrent) {
      // Suppress this attempt permanently, even if its confirmation reappears.
      setState(() => _silent = true);
      return;
    }
    if (widget.opening.isCurrent && result == HistoryDeletionState.deleted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.opening,
    builder: (context, _) {
      final opening = widget.opening;
      final pending = opening.state == HistoryDeletionState.pending;
      final error = _silent
          ? null
          : switch (opening.state) {
              HistoryDeletionState.failed =>
                'Could not delete workout. Please try again.',
              HistoryDeletionState.unavailable =>
                'This workout is unavailable. Close and reopen History.',
              HistoryDeletionState.superseded =>
                'Your local profile changed. Close and reopen History.',
              _ => null,
            };
      return PopScope(
        canPop: !pending,
        child: AlertDialog(
          title: const Text('Delete workout?'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(opening.name),
              Text(
                DateFormat(
                  'EEE, MMM d, y · h:mm a',
                ).format(opening.startedAt.toLocal()),
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
              onPressed: pending ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: opening.canSubmit ? _delete : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: Text(pending ? 'Deleting…' : 'Delete'),
            ),
          ],
        ),
      );
    },
  );
}
