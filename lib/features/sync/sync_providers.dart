import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup_providers.dart';
import 'data/sync_service.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(ref.watch(backupServiceProvider));
});
