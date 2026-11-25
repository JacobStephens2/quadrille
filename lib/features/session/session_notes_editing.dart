import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../../core/retained_opening.dart';
import 'data/session_repository.dart';
import 'session_providers.dart';

enum SessionNotesEditingState { idle, pending, succeeded, failed, superseded }

/// Retains the invoking Local profile generation and exact notes destination.
/// Capture from the rendering scope, independently of screen subscriptions.
class SessionNotesEditing {
  SessionNotesEditing._(this._owner, this._repository);

  final RetainedOpeningOwner _owner;
  final SessionRepository _repository;

  SessionNotesOpening edit(WorkoutSession session) => SessionNotesOpening._(
    _owner,
    _repository,
    session.id,
    session.generalNotes ?? '',
  );
}

final sessionNotesEditingProvider = Provider<SessionNotesEditing>((ref) {
  final generation = ref.watch(localProfileGenerationProvider);
  final repository = ref.watch(sessionRepositoryProvider);
  return SessionNotesEditing._(
    RetainedOpeningOwner(
      ref,
      generation,
      destinations: [
        RetainedDestination(
          repository,
          () => ref.read(sessionRepositoryProvider),
        ),
      ],
    ),
    repository,
  );
});

/// One fixed workout snapshot, with independent save admission and feedback.
class SessionNotesOpening extends RetainedOpening<SessionNotesEditingState> {
  SessionNotesOpening._(
    super.owner,
    this._repository,
    this.sessionId,
    this.initialNotes,
  ) : super(
        idle: SessionNotesEditingState.idle,
        pending: SessionNotesEditingState.pending,
        failed: SessionNotesEditingState.failed,
        superseded: SessionNotesEditingState.superseded,
      );

  final SessionRepository _repository;
  final String sessionId;
  final String initialNotes;

  String? get errorMessage => state == SessionNotesEditingState.failed
      ? 'Could not save notes. Please try again.'
      : null;

  Future<SessionNotesEditingState> save(String notes) => submitPersistence(
    () => _repository.setSessionNotes(sessionId, notes),
    mapCompleted: (_) => SessionNotesEditingState.succeeded,
  );
}
