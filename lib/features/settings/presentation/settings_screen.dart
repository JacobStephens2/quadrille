import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/domain/duration_format.dart';
import '../../../core/domain/enums.dart';
import '../../backup/backup_providers.dart';
import '../../backup/data/backup_io.dart';
import '../../backup/data/backup_service.dart';
import '../../sync/data/sync_service.dart';
import '../../sync/sync_providers.dart';
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
            const _SectionHeader('Cloud sync'),
            if ((s.syncToken ?? '').isEmpty)
              ListTile(
                leading: const Icon(Icons.cloud_off_outlined),
                title: const Text('Set up sync'),
                subtitle: const Text('Sync your data across devices'),
                onTap: () => _setupSync(context, ref, s.syncEndpoint),
              )
            else ...[
              ListTile(
                leading: Icon(Icons.cloud_done_outlined,
                    color: Theme.of(context).colorScheme.primary),
                title: const Text('Sync enabled'),
                subtitle: Text(s.syncEndpoint),
                trailing: TextButton(
                  onPressed: () => ref
                      .read(settingsRepositoryProvider)
                      .update(syncToken: const Value(null)),
                  child: const Text('Disconnect'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _upload(context, ref, s.syncEndpoint, s.syncToken!),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('Upload'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _download(context, ref, s.syncEndpoint, s.syncToken!),
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('Download'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(),
            const _SectionHeader('Data'),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Export backup'),
              subtitle: const Text(
                kIsWeb
                    ? 'Download a JSON backup of all your data'
                    : 'Copy a JSON backup of all your data to the clipboard',
              ),
              onTap: () => _export(context, ref),
            ),
            ListTile(
              leading: const Icon(Icons.upload_outlined),
              title: const Text('Import backup'),
              subtitle: const Text('Restore from a backup (replaces all data)'),
              onTap: () => _import(context, ref),
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

  Future<void> _setupSync(
    BuildContext context,
    WidgetRef ref,
    String currentEndpoint,
  ) async {
    final endpoint = TextEditingController(text: currentEndpoint);
    final tokenCtl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set up sync'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: endpoint,
              decoration: const InputDecoration(labelText: 'Server URL'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tokenCtl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Sync token',
                hintText: 'Paste the token from your server',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (result == true && tokenCtl.text.trim().isNotEmpty) {
      await ref.read(settingsRepositoryProvider).update(
            syncEndpoint: endpoint.text.trim(),
            syncToken: Value(tokenCtl.text.trim()),
          );
    }
  }

  Future<void> _upload(
    BuildContext context,
    WidgetRef ref,
    String endpoint,
    String token,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final revision = await ref.read(syncServiceProvider).upload(
            endpoint: endpoint,
            token: token,
            now: DateTime.now(),
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Uploaded to cloud (revision $revision)')),
      );
    } on SyncException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    String endpoint,
    String token,
  ) async {
    final confirmed = await _confirmReplace(context);
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await ref
          .read(syncServiceProvider)
          .download(endpoint: endpoint, token: token);
      messenger.showSnackBar(
        SnackBar(
          content: Text(summary == null
              ? 'The cloud has no data yet — upload first.'
              : 'Downloaded ${summary.exercises} exercises, '
                  '${summary.templates} templates, ${summary.sessions} sessions.'),
        ),
      );
    } on SyncException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final json =
        await ref.read(backupServiceProvider).exportJson(now: DateTime.now());
    await Clipboard.setData(ClipboardData(text: json));
    var message = 'Backup copied to clipboard';
    if (supportsFileDownload) {
      final stamp = DateFormat('yyyy-MM-dd').format(DateTime.now());
      try {
        await downloadText('quadrille-backup-$stamp.json', json);
        message = 'Backup downloaded (and copied to clipboard)';
      } catch (_) {/* fall back to clipboard-only message */}
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    var content = await pickTextFile();
    if (!context.mounted) return;
    content ??= await _pasteDialog(context);
    if (content == null || content.trim().isEmpty) return;
    if (!context.mounted) return;
    final confirmed = await _confirmReplace(context);
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary =
          await ref.read(backupServiceProvider).importJson(content);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Restored ${summary.exercises} exercises, '
              '${summary.templates} templates, ${summary.sessions} sessions.'),
        ),
      );
    } on BackupFormatException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import failed: ${e.message}')),
      );
    }
  }

  Future<String?> _pasteDialog(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste backup JSON'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '{ "format": "quadrille.backup", ... }',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmReplace(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace all data?'),
        content: const Text(
          'Importing replaces everything currently in Quadrille with the '
          'contents of the backup. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
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
