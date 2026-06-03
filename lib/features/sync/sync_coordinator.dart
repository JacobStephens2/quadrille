import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../auth/data/auth_api.dart';
import '../backup/backup_providers.dart';
import '../backup/data/backup_service.dart';
import '../settings/data/settings_repository.dart';
import '../settings/settings_providers.dart';

/// Drives per-user cloud sync over the account session.
///
/// Pull is a row-level MERGE (only newer rows apply), so it's inherently
/// safe — local unsynced edits survive and deletes propagate via tombstones.
/// Sign-in does pull-merge-push so the cloud also gains local-only rows.
class SyncCoordinator {
  SyncCoordinator(this._ref);

  final Ref _ref;

  AuthApi get _api => _ref.read(authApiProvider);
  BackupService get _backup => _ref.read(backupServiceProvider);
  SettingsRepository get _settings => _ref.read(settingsRepositoryProvider);

  Future<String?> _bearer() => _ref.read(tokenStoreProvider).read();
  bool get _canSync =>
      _ref.read(authControllerProvider).value?.canSync ?? false;

  /// Pushes local data; the server merges and returns the new revision.
  Future<int> uploadNow() async {
    final bearer = await _bearer();
    final payload = await _backup.exportSyncPayload();
    final revision = await _api.putSync(payload, bearer: bearer);
    await _settings.update(
      lastSyncedRevision: revision,
      lastSyncAt: Value(DateTime.now()),
    );
    return revision;
  }

  /// Pulls the cloud snapshot and merges it into local. Returns false if the
  /// cloud has nothing stored yet.
  Future<bool> downloadNow() async {
    final bearer = await _bearer();
    final remote = await _api.getSync(bearer: bearer);
    if (!remote.exists) return false;
    await _backup.mergeIntoLocal(remote.payload!);
    await _settings.update(
      lastSyncedRevision: remote.revision,
      lastSyncAt: Value(DateTime.now()),
    );
    return true;
  }

  /// Safe ordering on sign-in: merge cloud into local, then push the merged
  /// result so cloud gains any local-only rows (Gemini "pull-merge-push").
  Future<void> onSignIn() async {
    if (!_canSync) return;
    try {
      await downloadNow();
      await uploadNow();
    } catch (_) {/* offline; manual/auto sync will catch up */}
  }

  /// Auto-push after finishing a workout (best-effort).
  Future<void> pushAfterFinish() async {
    if (!_canSync) return;
    if (!(await _settings.read()).autoSync) return;
    try {
      await uploadNow();
    } catch (_) {}
  }

  /// Auto-pull on launch / when signing in (merge is safe, never clobbers).
  Future<void> pullOnLaunch() async {
    if (!_canSync) return;
    if (!(await _settings.read()).autoSync) return;
    try {
      await downloadNow();
    } catch (_) {}
  }
}

final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  return SyncCoordinator(ref);
});
