import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
        title: 'History',
        icon: Icons.history,
        phaseNote: 'Past sessions by date — Phase 2.',
      );
}
