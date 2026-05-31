import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/providers.dart';
import 'core/seed/starter_catalog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Build the container up front so the database opens (and seeds the starter
  // catalog on first launch) before the first frame, then hand the same
  // container to the widget tree.
  final container = ProviderContainer();
  await seedStarterDataIfEmpty(container.read(databaseProvider));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const QuadrilleApp(),
    ),
  );
}
