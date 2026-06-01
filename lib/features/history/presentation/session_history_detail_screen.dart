import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../session/presentation/session_exercise_card.dart';
import '../../session/session_providers.dart';

/// Read-only view of a completed session — the recorded grid.
class SessionHistoryDetailScreen extends ConsumerWidget {
  const SessionHistoryDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final grid = ref.watch(sessionGridProvider(sessionId));
    final dateFmt = DateFormat('EEE, MMM d · h:mm a');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/history'),
        ),
        title: Text(session.value?.name ?? 'Session'),
      ),
      body: grid.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          final started = session.value?.startedAt;
          final totalSets = rows.fold(0, (n, r) => n + r.completedCount);
          return ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 24),
            children: [
              if (started != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '${dateFmt.format(started.toLocal())}  ·  $totalSets sets',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              for (final row in rows)
                SessionExerciseCard(row: row, readOnly: true),
            ],
          );
        },
      ),
    );
  }
}
