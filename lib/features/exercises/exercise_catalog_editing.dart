import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/domain/enums.dart';
import '../../core/providers.dart';
import '../../core/retained_opening.dart';
import 'data/exercise_repository.dart';
import 'exercise_providers.dart';

/// Form values frozen before admission, independent of mutable text controls.
final class ExerciseCatalogDraft {
  const ExerciseCatalogDraft({
    required this.name,
    this.category = ExerciseCategory.other,
    this.defaultRestSeconds = 120,
    this.loadKind = LoadKind.externalWeight,
    this.isUnilateral = false,
    this.notes,
  });

  final String name;
  final ExerciseCategory category;
  final int defaultRestSeconds;
  final LoadKind loadKind;
  final bool isUnilateral;
  final String? notes;
}

enum ExerciseCatalogEditingState {
  idle,
  pending,
  succeeded,
  failed,
  superseded,
}

/// Capture from the rendering scope before constructing a catalog editor.
/// Retained independently of screens, but never beyond its exact destination.
class ExerciseCatalogEditing {
  ExerciseCatalogEditing._(this._owner, this._repository);

  final RetainedOpeningOwner _owner;
  final ExerciseRepository _repository;

  ExerciseCatalogOpening add() =>
      ExerciseCatalogOpening._(_owner, _repository, null);

  ExerciseCatalogOpening edit(Exercise exercise) =>
      ExerciseCatalogOpening._(_owner, _repository, exercise);
}

final exerciseCatalogEditingProvider = Provider<ExerciseCatalogEditing>((ref) {
  final generation = ref.watch(localProfileGenerationProvider);
  final repository = ref.watch(exerciseRepositoryProvider);
  return ExerciseCatalogEditing._(
    RetainedOpeningOwner(
      ref,
      generation,
      destinations: [
        RetainedDestination(
          repository,
          () => ref.read(exerciseRepositoryProvider),
        ),
      ],
    ),
    repository,
  );
});

/// One fixed Add/Edit intent and original snapshot, with per-opening admission.
class ExerciseCatalogOpening
    extends RetainedOpening<ExerciseCatalogEditingState> {
  ExerciseCatalogOpening._(super.owner, this._repository, this.initialExercise)
    : super(
        idle: ExerciseCatalogEditingState.idle,
        pending: ExerciseCatalogEditingState.pending,
        failed: ExerciseCatalogEditingState.failed,
        superseded: ExerciseCatalogEditingState.superseded,
      );

  final ExerciseRepository _repository;
  final Exercise? initialExercise;
  String? _validationMessage;

  String? get validationMessage => _validationMessage;
  String? get errorMessage => state == ExerciseCatalogEditingState.failed
      ? 'Could not save this exercise. Please try again.'
      : null;

  Future<ExerciseCatalogEditingState> save(ExerciseCatalogDraft draft) {
    final name = draft.name.trim();
    // Validation only at admission: a pending or succeeded opening returns
    // its claimed result and a non-current one returns superseded, each
    // without surfacing or clearing the validation message.
    if (canSubmit) {
      if (name.isEmpty) {
        _validationMessage = 'Required';
        notifyListeners();
        return Future.value(state);
      }
      _validationMessage = null;
    }
    return submitPersistence(() async {
      final notes = draft.notes?.trim();
      final normalizedNotes = notes == null || notes.isEmpty ? null : notes;
      final existing = initialExercise;
      if (existing == null) {
        await _repository.create(
          name: name,
          category: draft.category,
          defaultRestSeconds: draft.defaultRestSeconds,
          loadKind: draft.loadKind,
          isUnilateral: draft.isUnilateral,
          notes: normalizedNotes,
        );
      } else {
        await _repository.update(
          existing.id,
          name: name,
          category: draft.category,
          defaultRestSeconds: draft.defaultRestSeconds,
          loadKind: draft.loadKind,
          isUnilateral: draft.isUnilateral,
          notes: normalizedNotes,
        );
      }
    }, mapCompleted: (_) => ExerciseCatalogEditingState.succeeded);
  }
}
