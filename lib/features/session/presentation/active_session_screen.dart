import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../sync/sync_coordinator.dart';
import '../../timer/presentation/rest_timer_banner.dart';
import '../../timer/timer_providers.dart';
import '../domain/session_grid.dart';
import '../session_providers.dart';
import 'session_exercise_card.dart';
import 'set_entry_sheet.dart';

/// The live "fill in the grid" workout screen.
class ActiveSessionScreen extends ConsumerWidget {
  const ActiveSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final grid = ref.watch(sessionGridProvider(sessionId));
    final next = ref.watch(sessionRecommendationProvider(sessionId));
    final notes = session.value?.generalNotes;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/'),
        ),
        title: Text(session.value?.name ?? 'Workout'),
        actions: [
          IconButton(
            tooltip: 'Edit session notes',
            icon: const Icon(Icons.edit_note),
            onPressed: session.value == null
                ? null
                : () => _editNotes(context, ref, notes),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(context, ref, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'discard', child: Text('Discard session')),
            ],
          ),
        ],
      ),
      floatingActionButton: grid.maybeWhen(
        data: (rows) => FloatingActionButton.extended(
          onPressed: () => _complete(context, ref, rows),
          icon: const Icon(Icons.flag),
          label: const Text('Finish'),
        ),
        orElse: () => null,
      ),
      // Docked rest-timer countdown; the Scaffold lifts the FAB above it.
      bottomNavigationBar: const RestTimerBanner(),
      body: grid.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          return ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 96),
            children: [
              if (notes != null && notes.trim().isNotEmpty)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: ExpansionTile(
                    initiallyExpanded: true,
                    leading: const Icon(Icons.notes),
                    title: const Text('Session notes'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(notes),
                        ),
                      ),
                    ],
                  ),
                ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('This session has no exercises.')),
                ),
              for (final row in rows)
                SessionExerciseCard(
                  row: row,
                  nextSetId: next?.set.id,
                  onTapSet: (set) =>
                      showSetEntrySheet(context, row: row, set: set),
                  onAddSet: () => ref
                      .read(sessionRepositoryProvider)
                      .addSet(row.exercise.id),
                  onStartRest: () => ref
                      .read(restTimerControllerProvider)
                      .start(
                        duration: row.rest,
                        sessionId: sessionId,
                        sessionExerciseId: row.exercise.id,
                        label: row.exercise.displayName,
                      ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editNotes(
    BuildContext context,
    WidgetRef ref,
    String? initialNotes,
  ) async {
    final repository = ref.read(sessionRepositoryProvider);
    final notes = await showDialog<String>(
      context: context,
      builder: (_) => _SessionNotesDialog(initialNotes: initialNotes ?? ''),
    );
    if (notes == null) return;
    await repository.setSessionNotes(sessionId, notes);
  }

  Future<void> _complete(
    BuildContext context,
    WidgetRef ref,
    List<SessionGridRow> rows,
  ) async {
    final logged = rows.fold(0, (n, r) => n + r.completedCount);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish workout?'),
        content: Text('$logged sets logged. Move this session to history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(restTimerControllerProvider).skip();
      await ref.read(sessionRepositoryProvider).completeSession(sessionId);
      // Auto-push the finished workout if auto-sync is on (best-effort).
      unawaited(ref.read(syncCoordinatorProvider).pushAfterFinish());
      if (context.mounted) context.go('/history');
    }
  }

  Future<void> _onMenu(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    if (action != 'discard') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard session?'),
        content: const Text(
          'This permanently deletes the session and its logged sets.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(restTimerControllerProvider).skip();
      await ref.read(sessionRepositoryProvider).discardSession(sessionId);
      if (context.mounted) context.go('/');
    }
  }
}

class _SessionNotesDialog extends StatefulWidget {
  const _SessionNotesDialog({required this.initialNotes});

  final String initialNotes;

  @override
  State<_SessionNotesDialog> createState() => _SessionNotesDialogState();
}

class _SessionNotesDialogState extends State<_SessionNotesDialog> {
  late final _controller = TextEditingController(text: widget.initialNotes);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit session notes'),
      scrollable: true,
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 4,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Session notes'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
