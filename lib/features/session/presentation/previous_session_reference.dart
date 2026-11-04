import 'package:flutter/material.dart';

import '../domain/session_grid.dart';

/// The same compact historical reference in the grid and the entry sheet.
class PreviousSessionReference extends StatelessWidget {
  const PreviousSessionReference({super.key, required this.row});

  final SessionGridRow row;

  @override
  Widget build(BuildContext context) {
    final summary = row.previousSummary;
    if (summary == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          summary,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (row.isReadyToProgress)
          const Chip(
            avatar: Icon(Icons.trending_up, size: 16),
            label: Text('Ready to progress (+weight)'),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}
