import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../features/auth/auth_controller.dart';
import '../features/settings/settings_providers.dart';
import '../features/sync/sync_coordinator.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget. Holds the [GoRouter] for the lifetime of the app and applies
/// the grid-paper theme with system light/dark following.
class QuadrilleApp extends ConsumerStatefulWidget {
  const QuadrilleApp({super.key});

  @override
  ConsumerState<QuadrilleApp> createState() => _QuadrilleAppState();
}

class _QuadrilleAppState extends ConsumerState<QuadrilleApp> {
  late final GoRouter _router = createRouter();

  @override
  Widget build(BuildContext context) {
    // Hold the screen awake while a workout is in progress (if enabled).
    ref.listen<bool>(keepScreenAwakeActiveProvider, (_, keepAwake) {
      WakelockPlus.toggle(enable: keepAwake);
    });

    // Auto-pull once the account session resolves to sync-capable (covers both
    // launch-restore and fresh sign-in). Merge is safe, so this never clobbers.
    ref.listen(authControllerProvider, (prev, next) {
      final wasReady = prev?.value?.canSync ?? false;
      final isReady = next.value?.canSync ?? false;
      if (isReady && !wasReady) {
        ref.read(syncCoordinatorProvider).pullOnLaunch();
      }
    });

    return MaterialApp.router(
      title: 'Quadrille',
      debugShowCheckedModeBanner: false,
      theme: QuadrilleTheme.light(),
      darkTheme: QuadrilleTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}
