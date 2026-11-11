import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../template_providers.dart';
import '../template_management.dart';
import 'template_management_actions.dart';

/// Lists the workout templates (the user's sheets) and creates new ones.
class TemplatesScreen extends ConsumerWidget {
  const TemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(templatesProvider);
    final management = ref.watch(templateManagementProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Templates')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showTemplateName(context, management.create()),
        icon: const Icon(Icons.add),
        label: const Text('Template'),
      ),
      body: templates.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyTemplates();
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final t = list[i];
              return ListTile(
                leading: const Icon(Icons.grid_on_outlined),
                title: Text(t.name),
                subtitle: t.dayLabel == null ? null : Text(t.dayLabel!),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/templates/${t.id}'),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyTemplates extends StatelessWidget {
  const _EmptyTemplates();

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
              Icons.dashboard_customize_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No templates yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Recreate your workout sheets here — one template per day.',
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
