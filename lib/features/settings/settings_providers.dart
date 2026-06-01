import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../session/session_providers.dart';
import 'data/settings_repository.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(databaseProvider));
});

/// The current app settings (reactive).
final settingsProvider = StreamProvider<AppSettingsTableData>((ref) {
  return ref.watch(settingsRepositoryProvider).watch();
});

/// True when a workout is in progress and the user wants the screen kept on.
/// Drives the wake lock from the app root.
final keepScreenAwakeActiveProvider = Provider<bool>((ref) {
  final hasActiveSession = ref.watch(activeSessionProvider).value != null;
  final keep = ref.watch(settingsProvider).value?.keepScreenAwake ?? false;
  return hasActiveSession && keep;
});
