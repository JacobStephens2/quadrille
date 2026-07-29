import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import 'package:countdown_ring/countdown_ring.dart';
import '../../../core/domain/enums.dart';
import '../../auth/auth_controller.dart';
import '../../auth/data/auth_api.dart';
import '../../backup/backup_providers.dart';
import '../../backup/data/backup_io.dart';
import '../../backup/data/backup_service.dart';
import '../../sync/sync_coordinator.dart';
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
                Duration(seconds: s.defaultRestSeconds).compactLabel,
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
            const _SectionHeader('Account & cloud sync'),
            _AccountSection(settings: s),
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
      text: Duration(seconds: currentSeconds).compactLabel,
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
              final parsed = parseDuration(controller.text);
              Navigator.of(context).pop(parsed?.inSeconds);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// Account status + cloud-sync controls. Sign-in unlocks sync once the email
/// is verified.
class _AccountSection extends ConsumerWidget {
  const _AccountSection({required this.settings});

  final AppSettingsTableData settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authControllerProvider);
    return auth.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => ListTile(title: Text('Account error: $e')),
      data: (state) {
        if (!state.isSignedIn) {
          return ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('Sign in or create an account'),
            subtitle: const Text('Sync your workouts across your devices'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/signin'),
          );
        }
        final user = state.user!;
        return Column(
          children: [
            ListTile(
              leading: Icon(Icons.account_circle, color: theme.colorScheme.primary),
              title: Text(user.email),
              subtitle: Text(
                state.isVerified
                    ? (settings.lastSyncAt == null
                        ? 'Cloud sync ready'
                        : 'Last synced ${DateFormat('MMM d, h:mm a').format(settings.lastSyncAt!.toLocal())}')
                    : 'Email not verified',
              ),
              trailing: TextButton(
                onPressed: () =>
                    ref.read(authControllerProvider.notifier).logout(),
                child: const Text('Sign out'),
              ),
            ),
            if (!state.isVerified)
              _VerifyNotice()
            else ...[
              SwitchListTile(
                title: const Text('Auto-sync'),
                subtitle: const Text('Upload after a workout, pull on launch'),
                value: settings.autoSync,
                onChanged: (v) =>
                    ref.read(settingsRepositoryProvider).update(autoSync: v),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _sync(context, ref, upload: true),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('Upload'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _sync(context, ref, upload: false),
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('Download'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _sync(BuildContext context, WidgetRef ref,
      {required bool upload}) async {
    final messenger = ScaffoldMessenger.of(context);
    final coordinator = ref.read(syncCoordinatorProvider);
    try {
      if (upload) {
        await coordinator.uploadNow();
        messenger.showSnackBar(const SnackBar(content: Text('Uploaded to cloud')));
      } else {
        final had = await coordinator.downloadNow();
        messenger.showSnackBar(SnackBar(
          content: Text(had ? 'Synced from cloud' : 'The cloud has no data yet'),
        ));
      }
    } on AuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _VerifyNotice extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Verify your email to enable cloud sync. '
                  'Check your inbox for the link.'),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await ref
                          .read(authControllerProvider.notifier)
                          .resendVerification();
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Verification email sent')),
                      );
                    },
                    child: const Text('Resend email'),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(authControllerProvider.notifier).refresh(),
                    child: const Text("I've verified"),
                  ),
                ],
              ),
            ],
          ),
        ),
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
