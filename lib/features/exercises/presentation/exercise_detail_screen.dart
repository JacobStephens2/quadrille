import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../domain/exercise_history.dart';
import '../exercise_providers.dart';
import 'exercise_editor.dart';

/// Shows an exercise's all-time PRs and its per-session history.
class ExerciseDetailScreen extends ConsumerWidget {
  const ExerciseDetailScreen({super.key, required this.exerciseId});

  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercise = ref.watch(exerciseByIdProvider(exerciseId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/exercises'),
        ),
        title: Text(exercise.value?.name ?? 'Exercise'),
        actions: [
          if (exercise.value != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () =>
                  showExerciseEditor(context, existing: exercise.value),
            ),
        ],
      ),
      body: exercise.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (e) {
          if (e == null) {
            return const Center(child: Text('Exercise not found.'));
          }
          return _HistoryView(exercise: e);
        },
      ),
    );
  }
}

class _HistoryView extends ConsumerWidget {
  const _HistoryView({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(exerciseHistoryProvider(exercise.name));
    final theme = Theme.of(context);
    final dateFmt = DateFormat('EEE, MMM d');

    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (h) {
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _StatsCard(exercise: exercise, stats: h.stats),
            if (h.sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'No logged sets yet.\nFinish a workout with this exercise to see history.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              for (final session in h.sessions)
                _SessionRow(session: session, exercise: exercise, dateFmt: dateFmt),
          ],
        );
      },
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.exercise, required this.stats});

  final Exercise exercise;
  final ExerciseStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = exercise.loadKind == LoadKind.bodyweight ? '' : ' lb';
    String fmt(double? v) =>
        v == null ? '—' : (v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1));

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Personal records', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                _Stat(label: 'Best est. 1RM', value: '${fmt(stats.bestEstimatedOneRepMax)}$unit'),
                _Stat(label: 'Heaviest', value: '${fmt(stats.heaviestWeight)}$unit'),
                _Stat(label: 'Sessions', value: '${stats.sessionCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.exercise,
    required this.dateFmt,
  });

  final ExerciseHistorySession session;
  final Exercise exercise;
  final DateFormat dateFmt;

  @override
  Widget build(BuildContext context) {
    final showWeight = exercise.loadKind != LoadKind.bodyweight &&
        exercise.loadKind != LoadKind.none;

    String setLabel(SetEntry s) {
      final reps = exercise.isUnilateral
          ? '${s.leftReps ?? '–'}/${s.rightReps ?? '–'}'
          : '${s.reps ?? '–'}';
      if (showWeight && s.weight != null) {
        final w = s.weight! == s.weight!.roundToDouble()
            ? s.weight!.toInt().toString()
            : s.weight!.toString();
        return '$w × $reps';
      }
      return reps;
    }

    return ListTile(
      title: Text(dateFmt.format(session.date.toLocal())),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final s in session.sets)
              Chip(
                label: Text(setLabel(s)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ),
      isThreeLine: true,
    );
  }
}
