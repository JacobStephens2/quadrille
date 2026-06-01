import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/database/database.dart';
import '../../session/session_providers.dart';
import '../../templates/template_providers.dart';

/// The launch screen — "today's sheet". Resume an active workout, or start one
/// from a template.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeSessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Quadrille')),
      body: GridPaperBackground(
        child: active.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (session) => session != null
              ? _ResumeView(session: session)
              : const _StartView(),
        ),
      ),
    );
  }
}

class _ResumeView extends ConsumerWidget {
  const _ResumeView({required this.session});

  final WorkoutSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final grid = ref.watch(sessionGridProvider(session.id));
    final progress = grid.maybeWhen(
      data: (rows) {
        final done = rows.fold(0, (n, r) => n + r.completedCount);
        final total = rows.fold(0, (n, r) => n + r.totalCount);
        return '$done of $total sets logged';
      },
      orElse: () => null,
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Workout in progress', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(session.name, style: theme.textTheme.headlineSmall),
                if (progress != null) ...[
                  const SizedBox(height: 4),
                  Text(progress, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => context.go('/session/${session.id}'),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartView extends ConsumerWidget {
  const _StartView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final templates = ref.watch(templatesProvider);

    return templates.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.grid_on,
                      size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('Start by building a template',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Create a workout sheet on the Templates tab, then start it here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text('Start a workout', style: theme.textTheme.titleMedium),
            ),
            for (final t in list)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(t.name),
                  subtitle: t.dayLabel == null ? null : Text(t.dayLabel!),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _start(context, ref, t.id),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref, String templateId) async {
    final id =
        await ref.read(sessionRepositoryProvider).startFromTemplate(templateId);
    if (context.mounted) context.go('/session/$id');
  }
}
