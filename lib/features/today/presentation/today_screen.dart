import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/database/database.dart';
import '../../../core/providers.dart';

/// Reads the singleton settings row — a cheap end-to-end check that the
/// database opened, migrated, and seeded on launch.
final _dbReadyProvider = FutureProvider<AppSettingsTableData>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.appSettingsTable).getSingle();
});

/// The primary launch screen. In v1 this becomes "today's sheet": resume an
/// active workout or start one from a template. For now it confirms the stack
/// is live.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(_dbReadyProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: GridPaperBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_on, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Quadrille', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'The workout sheet that times your rest.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              ready.when(
                loading: () => const CircularProgressIndicator(),
                error: (e, _) => Text('Database error: $e'),
                data: (settings) => Chip(
                  avatar: const Icon(Icons.check_circle, size: 18),
                  label: Text('Database ready · units ${settings.units.label}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
