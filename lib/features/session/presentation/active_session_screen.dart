import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/presentation/presentation_opening.dart';
import '../../timer/presentation/rest_timer_banner.dart';
import '../../timer/timer_providers.dart';
import '../session_ending.dart';
import '../session_providers.dart';
import 'session_exercise_card.dart';
import 'session_notes.dart';
import 'set_entry_sheet.dart';

/// The live "fill in the grid" workout screen.
class ActiveSessionScreen extends ConsumerStatefulWidget {
  const ActiveSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ActiveSessionScreen> createState() =>
      _ActiveSessionScreenState();
}

class _ActiveSessionScreenState extends ConsumerState<ActiveSessionScreen> {
  SessionEndingHandle? _pendingEnding;

  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider(sessionId));
    final grid = ref.watch(sessionGridProvider(sessionId));
    final next = ref.watch(sessionRecommendationProvider(sessionId));
    final notes = session.value?.generalNotes;
    final ending = ref.watch(sessionEndingProvider(sessionId));
    return ListenableBuilder(
      listenable: ending,
      builder: (context, _) {
        final pending = identical(_pendingEnding, ending) || ending.isPending;
        final outcome = ending.outcome;
        final feedback = switch (outcome?.status) {
          SessionEndingStatus.failed =>
            'Could not end this workout: ${outcome!.error}. Please try again.',
          SessionEndingStatus.unavailable =>
            'This workout is no longer active. Return to Today to open a current workout.',
          _ => null,
        };
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => context.go('/'),
            ),
            title: Text(session.value?.name ?? 'Workout'),
            actions: [
              SessionNotesAction(sessionId: sessionId),
              PopupMenuButton<String>(
                enabled: !pending,
                onSelected: (_) =>
                    _confirmEnding(ending, SessionEndingIntent.discard),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'discard',
                    child: Text('Discard session'),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: grid.maybeWhen(
            data: (rows) => FloatingActionButton.extended(
              onPressed: pending
                  ? null
                  : () => _confirmEnding(
                      ending,
                      SessionEndingIntent.finish,
                      logged: rows.fold(0, (n, r) => n + r.completedCount),
                    ),
              icon: pending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.flag),
              label: Text(pending ? 'Ending…' : 'Finish'),
            ),
            orElse: () => null,
          ),
          // Docked rest-timer countdown; the Scaffold lifts the FAB above it.
          bottomNavigationBar: const RestTimerBanner(),
          body: grid.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (rows) {
              return ListView(
                padding: const EdgeInsets.only(top: 6, bottom: 96),
                children: [
                  if (feedback != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        feedback,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  SessionNotesCard(notes: notes),
                  if (rows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text('This session has no exercises.'),
                      ),
                    ),
                  for (final row in rows)
                    SessionExerciseCard(
                      row: row,
                      nextSetId: next?.set.id,
                      onTapSet: (set) =>
                          showSetEntrySheet(context, row: row, set: set),
                      onAddSet: () => ref
                          .read(sessionRepositoryProvider)
                          .addSet(row.exercise.id),
                      onStartRest: () => ref
                          .read(restTimerControllerProvider)
                          .start(
                            duration: row.rest,
                            sessionId: sessionId,
                            sessionExerciseId: row.exercise.id,
                            label: row.exercise.displayName,
                          ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmEnding(
    SessionEndingHandle ending,
    SessionEndingIntent intent, {
    int logged = 0,
  }) async {
    final opening = PresentationOpening.capture(context);
    if (!opening.isCurrent || !ending.isCurrent) return;
    final finishing = intent == SessionEndingIntent.finish;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(finishing ? 'Finish workout?' : 'Discard session?'),
        content: Text(
          finishing
              ? '$logged sets logged. Move this session to history?'
              : 'This permanently deletes the session and its logged sets.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(finishing ? 'Keep going' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(finishing ? 'Finish' : 'Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !opening.isCurrent ||
        !ending.isCurrent) {
      return;
    }
    setState(() {
      _pendingEnding = ending;
    });
    final outcome = await ending.end(intent);
    if (!mounted || !identical(_pendingEnding, ending)) return;
    setState(() => _pendingEnding = null);
    if (!ending.isCurrent || !opening.isCurrent) return;
    switch (outcome.status) {
      case SessionEndingStatus.ended:
        context.go(
          outcome.intent == SessionEndingIntent.finish ? '/history' : '/',
        );
      case SessionEndingStatus.failed:
      case SessionEndingStatus.unavailable:
      case SessionEndingStatus.superseded:
        break;
    }
  }
}
