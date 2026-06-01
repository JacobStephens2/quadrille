import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../session/session_providers.dart';

/// Past (completed) sessions, newest first.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final dateFmt = DateFormat('EEE, MMM d');

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyHistory();
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = list[i];
              return ListTile(
                leading: const Icon(Icons.event_available_outlined),
                title: Text(s.name),
                subtitle: Text(dateFmt.format(s.startedAt.toLocal())),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/history/${s.id}'),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No completed workouts yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Finish a session and it lands here.',
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
