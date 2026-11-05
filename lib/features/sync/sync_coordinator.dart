import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../auth/auth_controller.dart';
import '../auth/data/auth_api.dart';
import '../backup/backup_providers.dart';
import '../backup/data/backup_service.dart';
import '../settings/data/settings_repository.dart';
import '../settings/settings_providers.dart';

/// An invoked sync lost its owner. This is neither success nor an empty cloud.
class SyncSuperseded implements Exception {
  const SyncSuperseded();
}

class _SyncOwner {
  _SyncOwner(this.context, this.database, this.backup, this.settings, this.api);

  final AuthSyncContext context;
  final QuadrilleDatabase database;
  final BackupService backup;
  final SettingsRepository settings;
  final AuthApi api;
  Future<void> tail = Future.value();
}

/// Account sync owns lifetime, ordering, and persistence behind five intents.
/// A generation has one FIFO; replacing it abandons that FIFO immediately.
class SyncCoordinator {
  SyncCoordinator(this._ref) {
    _ref.listen(authSyncContextProvider, (_, _) => _invalidate());
    _ref.listen(currentProfileProvider, (_, _) => _invalidate());
    _ref.listen(databaseProvider, (_, _) => _invalidate());
    _ref.onDispose(_invalidate);
  }

  final Ref _ref;
  _SyncOwner? _owner;

  void _invalidate() => _owner = null;

  _SyncOwner _capture() {
    if (!_ref.mounted) throw const SyncSuperseded();
    final context = _ref.read(authSyncContextProvider);
    final profile = _ref.read(currentProfileProvider);
    if (context == null ||
        context.profileName != userProfileName(context.accountId) ||
        context.profileName != profile) {
      throw const AuthException('Sign in with a verified account to sync.');
    }
    final database = _ref.read(databaseProvider);
    final previous = _owner;
    if (previous != null &&
        identical(previous.context.generation, context.generation) &&
        identical(previous.database, database)) {
      return previous;
    }
    return _owner = _SyncOwner(
      context,
      database,
      _ref.read(backupServiceProvider),
      _ref.read(settingsRepositoryProvider),
      _ref.read(authApiProvider),
    );
  }

  void _check(_SyncOwner owner) {
    if (!_ref.mounted ||
        !identical(_owner, owner) ||
        !identical(_ref.read(authSyncContextProvider), owner.context) ||
        _ref.read(currentProfileProvider) != owner.context.profileName ||
        !identical(_ref.read(databaseProvider), owner.database)) {
      throw const SyncSuperseded();
    }
  }

  Future<T> _enqueue<T>(Future<T> Function(_SyncOwner) command) {
    // Capture synchronously at invocation, before waiting on the FIFO.
    final owner = _capture();
    final result = owner.tail.then((_) async {
      try {
        _check(owner);
        final value = await command(owner);
        _check(owner);
        return value;
      } catch (_) {
        _check(owner);
        rethrow;
      }
    });
    owner.tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Push local workout rows; manual sync ignores Auto-sync.
  Future<int> uploadNow() async => _enqueue(_upload);

  Future<int> _upload(_SyncOwner owner) async {
    _check(owner);
    final payload = await owner.backup.exportSyncPayload();
    _check(owner);
    final revision = await owner.api.putSync(
      payload,
      bearer: owner.context.bearer,
      expectedAccount: owner.context.accountId,
    );
    _check(owner);
    await _record(owner, revision);
    return revision;
  }

  /// Merge cloud rows. False means the current owner's cloud is empty.
  Future<bool> downloadNow() async => _enqueue(_download);

  Future<bool> _download(_SyncOwner owner) async {
    _check(owner);
    final remote = await owner.api.getSync(
      bearer: owner.context.bearer,
      expectedAccount: owner.context.accountId,
    );
    _check(owner);
    if (!remote.exists) return false;
    await owner.backup.mergeIntoLocal(remote.payload!);
    _check(owner);
    await _record(owner, remote.revision);
    return true;
  }

  Future<void> _record(_SyncOwner owner, int revision) async {
    _check(owner);
    await owner.settings.update(
      lastSyncedRevision: revision,
      lastSyncAt: Value(DateTime.now()),
    );
    _check(owner);
  }

  /// Sign-in's pull-merge-push is one command, even with Auto-sync off. Empty
  /// cloud still permits upload, while a failed or obsolete pull stops it.
  Future<void> onSignIn() async {
    try {
      await _enqueue((owner) async {
        await _download(owner);
        _check(owner);
        await _upload(owner);
      });
    } catch (_) {
      /* best effort */
    }
  }

  Future<void> _automatic({required bool upload}) async {
    try {
      await _enqueue((owner) async {
        final settings = await owner.settings.read();
        _check(owner);
        if (!settings.autoSync) return;
        if (upload) {
          await _upload(owner);
        } else {
          await _download(owner);
        }
      });
    } catch (_) {
      /* includes policy reads and ineligible accounts */
    }
  }

  Future<void> pushAfterFinish() => _automatic(upload: true);

  Future<void> pullOnLaunch() => _automatic(upload: false);
}

final syncCoordinatorProvider = Provider<SyncCoordinator>(SyncCoordinator.new);
