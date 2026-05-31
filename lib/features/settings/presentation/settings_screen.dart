import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
        title: 'Settings',
        icon: Icons.settings_outlined,
        phaseNote: 'Units, rest defaults, timer & watch options — Phase 3+.',
      );
}
