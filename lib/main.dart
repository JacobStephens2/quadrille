import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/providers.dart';
import 'core/seed/starter_catalog.dart';
import 'features/auth/auth_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();

  // Reopen the profile that was active last session (guest or a specific
  // account) before the first frame, so the right local DB is in use.
  final persistedProfile = await container.read(profileStoreProvider).read();
  if (persistedProfile != null && persistedProfile.isNotEmpty) {
    container.read(currentProfileProvider.notifier).set(persistedProfile);
  }

  // Seed the starter catalog only for the guest profile (accounts get data
  // from carry-over / cloud sync).
  if (container.read(currentProfileProvider) == localProfileName) {
    await seedStarterDataIfEmpty(container.read(databaseProvider));
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const QuadrilleApp(),
    ),
  );
}
