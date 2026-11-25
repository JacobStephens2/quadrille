import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../../core/retained_opening.dart';
import '../session/data/session_repository.dart';
import '../session/session_providers.dart';

enum HistoryDeletionState {
  idle,
  pending,
  deleted,
  unavailable,
  failed,
  superseded,
}

/// Retains one Local profile generation and its exact Session destination.
class HistoryDeletion {
  HistoryDeletion._(this._owner, this._repository);

  final RetainedOpeningOwner _owner;
  final SessionRepository _repository;

  HistoryDeletionOpening open(WorkoutSession workout) =>
      HistoryDeletionOpening._(
        _owner,
        _repository,
        workout.id,
        workout.name,
        workout.startedAt,
      );
}

final historyDeletionProvider = Provider<HistoryDeletion>((ref) {
  final generation = ref.watch(localProfileGenerationProvider);
  final repository = ref.watch(sessionRepositoryProvider);
  return HistoryDeletion._(
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

/// One confirmation's immutable target, observable state and deletion authority.
class HistoryDeletionOpening extends RetainedOpening<HistoryDeletionState> {
  HistoryDeletionOpening._(
    super.owner,
    this._repository,
    this.sessionId,
    this.name,
    this.startedAt,
  ) : super(
        idle: HistoryDeletionState.idle,
        pending: HistoryDeletionState.pending,
        failed: HistoryDeletionState.failed,
        superseded: HistoryDeletionState.superseded,
      );

  final SessionRepository _repository;
  final String sessionId;
  final String name;
  final DateTime startedAt;

  Future<HistoryDeletionState> delete() => submitPersistence(
    () => _repository.deleteCompletedSession(sessionId),
    mapCompleted: (deleted) => deleted
        ? HistoryDeletionState.deleted
        : HistoryDeletionState.unavailable,
  );
}
