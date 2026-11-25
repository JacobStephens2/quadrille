import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/formatting/workout_duration.dart';
import '../../session/presentation/session_exercise_card.dart';
import '../../session/presentation/session_notes.dart';
import '../../session/session_providers.dart';

/// The recorded grid of a completed session, with editable overall notes.
class SessionHistoryDetailScreen extends ConsumerWidget {
  const SessionHistoryDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId)).loadedValue;
    final grid = ref.watch(sessionGridProvider(sessionId));
    final dateFmt = DateFormat('EEE, MMM d · h:mm a');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/history'),
        ),
        title: Text(session?.name ?? 'Session'),
        actions: [SessionNotesAction(sessionId: sessionId)],
      ),
      body: grid.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          final started = session?.startedAt;
          final notes = session?.generalNotes;
          final totalSets = rows.fold(0, (n, r) => n + r.completedCount);
          final duration = started == null
              ? null
              : completedWorkoutDurationLabel(
                  startedAt: started,
                  completedAt: session?.completedAt,
                );
          return ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 24),
            children: [
              if (started != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '${dateFmt.format(started.toLocal())}  ·  $totalSets sets'
                    '${duration == null ? '' : '  ·  $duration'}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              if (notes != null) SessionNotesCard(notes: notes),
              for (final row in rows)
                SessionExerciseCard(row: row, readOnly: true),
            ],
          );
        },
      ),
    );
  }
}
