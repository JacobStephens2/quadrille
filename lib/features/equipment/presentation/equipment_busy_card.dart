import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../domain/equipment_busy_history.dart';
import '../equipment_providers.dart';

class EquipmentBusyButton extends ConsumerWidget {
  const EquipmentBusyButton({super.key, required this.exerciseName});

  final String exerciseName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saving = ref.watch(equipmentBusyControllerProvider(exerciseName));
    return TextButton.icon(
      onPressed: saving.isLoading ? null : () => _record(context, ref),
      icon: const Icon(Icons.people_outline, size: 18),
      label: const Text('Equipment busy'),
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(equipmentBusyRepositoryProvider);
    final controller = ref.read(
      equipmentBusyControllerProvider(exerciseName).notifier,
    );
    bool isCurrent() =>
        context.mounted &&
        identical(repository, ref.read(equipmentBusyRepositoryProvider));
    final id = await controller.record();
    if (!context.mounted || !isCurrent()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          id == null
              ? 'Could not save busy report. Try again.'
              : 'Equipment was busy',
        ),
        action: id == null
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  if (!isCurrent()) return;
                  final undone = await controller.undo(id);
                  if (!undone && context.mounted && isCurrent()) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not undo busy report. Try again.'),
                      ),
                    );
                  }
                },
              ),
      ),
    );
  }
}

/// Shared by catalog details and a workout's Busy times sheet, so exercises
/// that exist only in a template can still show their observations.
class EquipmentBusyCard extends ConsumerWidget {
  const EquipmentBusyCard({super.key, required this.exerciseName});

  final String exerciseName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(equipmentBusyHistoryProvider(exerciseName));
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Equipment busy times', style: theme.textTheme.titleMedium),
            Text(
              'Equipment used for $exerciseName',
              style: theme.textTheme.bodySmall,
            ),
            EquipmentBusyButton(exerciseName: exerciseName),
            history.when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => const Text('Could not load busy reports.'),
              data: (h) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    h.reports.isEmpty
                        ? 'No busy reports yet.'
                        : '${h.reports.length} busy ${h.reports.length == 1 ? 'report' : 'reports'}',
                  ),
                  for (final time in h.times)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('${_timeLabel(time)} · ${time.count}'),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Most reported times first, using the time at the gym. '
                    'Unreported times may also be busy.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeLabel(EquipmentBusyTime time) {
    // January 1, 2024 was a Monday. This date only formats a weekday/hour.
    final start = DateTime.utc(2024, 1, time.weekday, time.hour);
    final end = start.add(const Duration(hours: 1));
    return '${DateFormat('EEE, h a').format(start)} - ${DateFormat('h a').format(end)}';
  }
}

Future<void> showEquipmentBusyTimes(
  BuildContext context, {
  required String exerciseName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          child: EquipmentBusyCard(exerciseName: exerciseName),
        ),
      ),
    ),
  );
}
