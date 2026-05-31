import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class ExercisesScreen extends StatelessWidget {
  const ExercisesScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
        title: 'Exercises',
        icon: Icons.fitness_center,
        phaseNote: 'Your exercise catalog — Phase 1.',
      );
}
