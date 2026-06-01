import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/database.dart';
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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/'),
        ),
        title: Text(session.value?.name ?? 'Workout'),
        actions: [
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
      body: grid.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('This session has no exercises.'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 96),
            children: [
              for (final row in rows)
                SessionExerciseCard(
                  row: row,
                  onTapSet: (set) => _logSet(context, ref, row, set),
                  onAddSet: () => ref
                      .read(sessionRepositoryProvider)
                      .addSet(row.exercise.id),
                ),
            ],
          );
        },
      ),
    );
  }

  void _logSet(
    BuildContext context,
    WidgetRef ref,
    SessionGridRow row,
    SetEntry set,
  ) {
    // Carry the weight forward from the most recent completed set before this.
    double? prefill;
    for (final s in row.sets) {
      if (s.setNumber < set.setNumber && s.weight != null) prefill = s.weight;
    }
    showSetEntrySheet(
      context,
      exercise: row.exercise,
      set: set,
      prefillWeight: prefill,
    );
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
      await ref.read(sessionRepositoryProvider).completeSession(sessionId);
      if (context.mounted) context.go('/history');
    }
  }

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String action) async {
    if (action != 'discard') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard session?'),
        content: const Text('This permanently deletes the session and its logged sets.'),
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
      await ref.read(sessionRepositoryProvider).discardSession(sessionId);
      if (context.mounted) context.go('/');
    }
  }
}
