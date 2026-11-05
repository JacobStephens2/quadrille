import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import 'data/backup_service.dart';

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.watch(databaseProvider));
});

/// Copies guest rows into a destination before adopting its Local profile.
/// This temporary connection owns its lifetime; the active guest database
/// remains open and durable until the destination merge has committed.
final adoptionBackupServiceProvider = Provider.autoDispose
    .family<BackupService, String>((ref, profile) {
      final database = QuadrilleDatabase(profile);
      ref.onDispose(database.close);
      return BackupService(database);
    });
