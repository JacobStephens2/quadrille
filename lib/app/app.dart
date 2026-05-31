import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
