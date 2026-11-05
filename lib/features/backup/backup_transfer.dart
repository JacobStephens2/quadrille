import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import 'backup_providers.dart';
import 'data/backup_io.dart' as io;
import 'data/backup_service.dart';

enum BackupTransferStatus {
  exported,
  restored,
  cancelled,
  superseded,
  busy,
  failed,
}

class BackupTransferOutcome {
  const BackupTransferOutcome._(
    this.status, {
    this.downloaded,
    this.summary,
    this.error,
  });

  final BackupTransferStatus status;
  final bool? downloaded;
  final ImportSummary? summary;
  final Object? error;
}

/// The platform boundary. Persistence and stage ordering stay in Backup transfer.
abstract interface class BackupPlatform {
  Future<String?> pickText();
  Future<void> copyText(String content);
  bool get supportsDownload;
  Future<void> download(String filename, String content);
}

class _SystemBackupPlatform implements BackupPlatform {
  @override
  Future<String?> pickText() => io.pickTextFile();

  @override
  Future<void> copyText(String content) =>
      Clipboard.setData(ClipboardData(text: content));

  @override
  bool get supportsDownload => io.supportsFileDownload;

  @override
  Future<void> download(String filename, String content) =>
      io.downloadText(filename, content);
}

final backupPlatformProvider = Provider<BackupPlatform>(
  (ref) => _SystemBackupPlatform(),
);
final backupNowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Settings supplies presentation only; the module decides when it is eligible.
class BackupPresentation {
  const BackupPresentation({
    required this.isAvailable,
    required this.paste,
    required this.confirmReplacement,
    required this.feedback,
  });

  final bool Function() isAvailable;
  final Future<String?> Function() paste;
  final Future<bool?> Function() confirmReplacement;
  final void Function(String message) feedback;
}

/// One permanent Local profile/database generation, independent of screen life.
/// Retired waits may settle, but can never authorize another stage.
class BackupTransfer extends ChangeNotifier {
  BackupTransfer._(this._ref)
    : _profile = _ref.read(currentProfileProvider),
      _database = _ref.read(databaseProvider),
      _backup = _ref.read(backupServiceProvider),
      _platform = _ref.read(backupPlatformProvider),
      _now = _ref.read(backupNowProvider);

  final Ref _ref;
  final String _profile;
  final QuadrilleDatabase _database;
  final BackupService _backup;
  final BackupPlatform _platform;
  final DateTime Function() _now;
  bool _valid = true;
  bool _disposed = false;
  bool _pending = false;

  bool get isPending => _pending;

  bool get _isCurrent =>
      _valid &&
      _ref.mounted &&
      _ref.read(currentProfileProvider) == _profile &&
      identical(_ref.read(databaseProvider), _database);

  void _retire() => _valid = false;

  @override
  void dispose() {
    _retire();
    _disposed = true;
    super.dispose();
  }

  Future<BackupTransferOutcome> export(BackupPresentation presentation) =>
      _start(presentation, exporting: true);

  Future<BackupTransferOutcome> restore(BackupPresentation presentation) =>
      _start(presentation, exporting: false);

  Future<BackupTransferOutcome> _start(
    BackupPresentation presentation, {
    required bool exporting,
  }) async {
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    if (_pending) {
      return const BackupTransferOutcome._(BackupTransferStatus.busy);
    }
    // Claim before any adapter or listener can re-enter.
    _pending = true;
    try {
      notifyListeners();
      BackupTransferOutcome outcome;
      try {
        outcome = exporting ? await _export() : await _restore(presentation);
      } catch (error) {
        outcome = BackupTransferOutcome._(
          BackupTransferStatus.failed,
          error: error,
        );
      }
      if (!_isCurrent) {
        return const BackupTransferOutcome._(BackupTransferStatus.superseded);
      }
      final message = _message(outcome, exporting: exporting);
      if (message != null && presentation.isAvailable() && _isCurrent) {
        presentation.feedback(message);
      }
      return _isCurrent
          ? outcome
          : const BackupTransferOutcome._(BackupTransferStatus.superseded);
    } catch (error) {
      // Presentation failures must settle too, without recursively sending feedback.
      return _isCurrent
          ? BackupTransferOutcome._(BackupTransferStatus.failed, error: error)
          : const BackupTransferOutcome._(BackupTransferStatus.superseded);
    } finally {
      _pending = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<BackupTransferOutcome> _export() async {
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    final now = _now();
    final content = await _backup.exportJson(now: now);
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    await _platform.copyText(content);
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    var downloaded = false;
    if (_platform.supportsDownload) {
      if (!_isCurrent) {
        return const BackupTransferOutcome._(BackupTransferStatus.superseded);
      }
      final stamp = DateFormat('yyyy-MM-dd').format(now.toLocal());
      try {
        await _platform.download('quadrille-backup-$stamp.json', content);
        downloaded = true;
      } catch (_) {
        // The clipboard already succeeded; a current owner can use that copy.
      }
      if (!_isCurrent) {
        return const BackupTransferOutcome._(BackupTransferStatus.superseded);
      }
    }
    return BackupTransferOutcome._(
      BackupTransferStatus.exported,
      downloaded: downloaded,
    );
  }

  Future<BackupTransferOutcome> _restore(
    BackupPresentation presentation,
  ) async {
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    if (!presentation.isAvailable()) {
      return const BackupTransferOutcome._(BackupTransferStatus.cancelled);
    }
    var content = await _platform.pickText();
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    if (!presentation.isAvailable()) {
      return const BackupTransferOutcome._(BackupTransferStatus.cancelled);
    }
    if (content == null) {
      content = await presentation.paste();
      if (!_isCurrent) {
        return const BackupTransferOutcome._(BackupTransferStatus.superseded);
      }
      if (!presentation.isAvailable()) {
        return const BackupTransferOutcome._(BackupTransferStatus.cancelled);
      }
    }
    if (content == null || content.trim().isEmpty) {
      return const BackupTransferOutcome._(BackupTransferStatus.cancelled);
    }
    final confirmed = await presentation.confirmReplacement();
    if (!_isCurrent) {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
    if (!presentation.isAvailable() || confirmed != true) {
      return const BackupTransferOutcome._(BackupTransferStatus.cancelled);
    }
    try {
      final summary = await _backup.importJson(
        content,
        isEligible: () => _isCurrent,
      );
      return BackupTransferOutcome._(
        BackupTransferStatus.restored,
        summary: summary,
      );
    } on BackupRestoreSuperseded {
      return const BackupTransferOutcome._(BackupTransferStatus.superseded);
    }
  }

  String? _message(
    BackupTransferOutcome outcome, {
    required bool exporting,
  }) => switch (outcome.status) {
    BackupTransferStatus.exported =>
      outcome.downloaded!
          ? 'Backup downloaded (and copied to clipboard)'
          : 'Backup copied to clipboard',
    BackupTransferStatus.restored =>
      'Restored ${outcome.summary!.exercises} exercises, '
          '${outcome.summary!.templates} templates, ${outcome.summary!.sessions} sessions.',
    BackupTransferStatus.failed =>
      outcome.error is BackupFormatException
          ? 'Import failed: ${(outcome.error! as BackupFormatException).message}'
          : '${exporting ? 'Export' : 'Import'} failed. Please try again.',
    _ => null,
  };
}

final backupTransferProvider = Provider<BackupTransfer>((ref) {
  ref.watch(currentProfileProvider);
  ref.watch(databaseProvider);
  final transfer = BackupTransfer._(ref);
  // Listening in addition to watching catches A-to-B-to-A without a lazy read.
  ref.listen(currentProfileProvider, (_, _) => transfer._retire());
  ref.listen(databaseProvider, (_, _) => transfer._retire());
  ref.onDispose(transfer.dispose);
  return transfer;
});
