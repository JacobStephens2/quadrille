import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/duration_format.dart';
import '../../../core/domain/enums.dart';
import '../settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final repo = ref.read(settingsRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (s) => ListView(
          children: [
            const _SectionHeader('Units'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<WeightUnit>(
                segments: const [
                  ButtonSegment(value: WeightUnit.lb, label: Text('lb')),
                  ButtonSegment(value: WeightUnit.kg, label: Text('kg')),
                ],
                selected: {s.units},
                onSelectionChanged: (sel) => repo.update(units: sel.first),
              ),
            ),
            const Divider(),
            const _SectionHeader('Rest timer'),
            ListTile(
              title: const Text('Default rest'),
              subtitle: const Text('Used when an exercise has no rest set'),
              trailing: Text(
                Duration(seconds: s.defaultRestSeconds).restLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              onTap: () async {
                final picked = await _editRest(context, s.defaultRestSeconds);
                if (picked != null) {
                  await repo.update(defaultRestSeconds: picked);
                }
              },
            ),
            SwitchListTile(
              title: const Text('Auto-start rest after a set'),
              subtitle: const Text('Begin the countdown when you log a set'),
              value: s.autoStartTimer,
              onChanged: (v) => repo.update(autoStartTimer: v),
            ),
            const Divider(),
            const _SectionHeader('During a workout'),
            SwitchListTile(
              title: const Text('Keep screen awake'),
              subtitle: const Text('Prevent the screen from sleeping mid-session'),
              value: s.keepScreenAwake,
              onChanged: (v) => repo.update(keepScreenAwake: v),
            ),
            const Divider(),
            const _SectionHeader('About'),
            const ListTile(
              title: Text('Quadrille'),
              subtitle: Text('The workout sheet that times your rest.'),
            ),
          ],
        ),
      ),
    );
  }

  Future<int?> _editRest(BuildContext context, int currentSeconds) {
    final controller = TextEditingController(
      text: Duration(seconds: currentSeconds).restLabel,
    );
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Default rest'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Rest',
            hintText: "90s, 2', 1:30",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = parseRest(controller.text);
              Navigator.of(context).pop(parsed?.inSeconds);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
