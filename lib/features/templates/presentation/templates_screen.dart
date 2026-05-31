import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class TemplatesScreen extends StatelessWidget {
  const TemplatesScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
        title: 'Templates',
        icon: Icons.dashboard_customize_outlined,
        phaseNote: 'Build your Push/Pull/Legs sheets — Phase 1.',
      );
}
