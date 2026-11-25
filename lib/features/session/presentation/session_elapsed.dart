import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/workout_duration.dart';
import '../session_elapsed_provider.dart';

/// Live overall workout length counting up from Session starting. Its own
/// Consumer widget so each tick rebuilds only this label, not the grid.
class SessionElapsed extends ConsumerWidget {
  const SessionElapsed({super.key, required this.startedAt});

  final DateTime startedAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elapsed = ref.watch(sessionElapsedProvider(startedAt));
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.timer_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          'Elapsed ${workoutElapsedLabel(elapsed)}',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}
