import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../backup/data/backup_service.dart';
import '../settings/data/settings_repository.dart';
import '../settings/settings_providers.dart';
import 'data/sync_service.dart';
import 'sync_providers.dart';

/// Outcome of an auto-pull attempt (for logging / optional UI).
enum PullOutcome {
  notConfigured,
  upToDate,
  pulled,
  skippedLocalChanges,
  failed,
}

/// Orchestrates sync with revision bookkeeping, used by both the manual buttons
/// and the auto push-on-finish / pull-on-launch hooks.
///
/// Last-write-wins, but a pull is only auto-applied when this device has no
/// changes since its last sync — so an automatic pull can never silently
/// clobber unsynced local edits.
class SyncCoordinator {
  SyncCoordinator(this._ref);

  final Ref _ref;

  QuadrilleDatabase get _db => _ref.read(databaseProvider);
  SyncService get _sync => _ref.read(syncServiceProvider);
  SettingsRepository get _settings => _ref.read(settingsRepositoryProvider);

  /// Pushes local data to the cloud and records the new revision/time.
  Future<int> uploadNow(AppSettingsTableData s) async {
    final revision = await _sync.upload(
      endpoint: s.syncEndpoint,
      token: s.syncToken!,
      now: DateTime.now(),
    );
    await _settings.update(
      lastSyncedRevision: revision,
      lastSyncAt: Value(DateTime.now()),
    );
    return revision;
  }

  /// Pulls and replaces local data, recording the revision/time. Returns null
  /// if the cloud has nothing yet.
  Future<ImportSummary?> downloadNow(AppSettingsTableData s) async {
    final remote =
        await _sync.fetchState(endpoint: s.syncEndpoint, token: s.syncToken!);
    if (!remote.exists) return null;
    final summary = await _sync.applyPayload(remote.payload!);
    await _restoreSyncSettings(s, remote.revision);
    return summary;
  }

  /// The payload includes app_settings, so importing it would otherwise clobber
  /// this device's own sync credentials. Re-write them (plus bookkeeping) after
  /// any pull so sync stays connected on this device.
  Future<void> _restoreSyncSettings(
    AppSettingsTableData local,
    int revision,
  ) async {
    await _settings.update(
      syncEndpoint: local.syncEndpoint,
      syncToken: Value(local.syncToken),
      autoSync: local.autoSync,
      lastSyncedRevision: revision,
      lastSyncAt: Value(DateTime.now()),
    );
  }

  /// Auto push after finishing a workout (best-effort; errors are swallowed).
  Future<void> pushAfterFinish() async {
    final s = await _settings.read();
    if (!s.autoSync || (s.syncToken ?? '').isEmpty) return;
    try {
      await uploadNow(s);
    } catch (_) {/* offline / server down — manual sync still available */}
  }

  /// Auto pull on launch, but only when safe (no local changes since last sync
  /// and the cloud has a newer revision).
  Future<PullOutcome> pullOnLaunch() async {
    final s = await _settings.read();
    if (!s.autoSync || (s.syncToken ?? '').isEmpty) {
      return PullOutcome.notConfigured;
    }
    try {
      final remote =
          await _sync.fetchState(endpoint: s.syncEndpoint, token: s.syncToken!);
      if (!remote.exists || remote.revision <= s.lastSyncedRevision) {
        return PullOutcome.upToDate;
      }
      final localModified = await _localLastModified();
      final hasLocalChanges = localModified != null &&
          (s.lastSyncAt == null || localModified.isAfter(s.lastSyncAt!));
      if (hasLocalChanges) return PullOutcome.skippedLocalChanges;

      await _sync.applyPayload(remote.payload!);
      await _restoreSyncSettings(s, remote.revision);
      return PullOutcome.pulled;
    } catch (_) {
      return PullOutcome.failed;
    }
  }

  /// Newest `updatedAt` across all user-data tables, or null if empty.
  Future<DateTime?> _localLastModified() async {
    final row = await _db.customSelect(
      'SELECT max(m) AS m FROM ('
      'SELECT max(updated_at) m FROM exercises '
      'UNION ALL SELECT max(updated_at) FROM workout_templates '
      'UNION ALL SELECT max(updated_at) FROM template_exercises '
      'UNION ALL SELECT max(updated_at) FROM workout_sessions '
      'UNION ALL SELECT max(updated_at) FROM session_exercises '
      'UNION ALL SELECT max(updated_at) FROM set_entries)',
    ).getSingle();
    final seconds = row.read<int?>('m');
    return seconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
}

final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  return SyncCoordinator(ref);
});
