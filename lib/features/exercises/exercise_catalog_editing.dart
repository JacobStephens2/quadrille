import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/domain/enums.dart';
import '../../core/providers.dart';
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
  ExerciseCatalogEditing._(this._ref, this._generation, this._repository) {
    _generation.addListener(_retire);
  }

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final ExerciseRepository _repository;
  final _openings = <ExerciseCatalogOpening>{};
  bool _active = true;

  bool get _isCurrent {
    if (!_active) return false;
    if (!_ref.mounted ||
        !_generation.isCurrent ||
        !identical(_repository, _ref.read(exerciseRepositoryProvider))) {
      _retire();
    }
    return _active;
  }

  ExerciseCatalogOpening add() => ExerciseCatalogOpening._(this, null);

  ExerciseCatalogOpening edit(Exercise exercise) =>
      ExerciseCatalogOpening._(this, exercise);

  void _retire() {
    if (!_active) return;
    _active = false;
    _generation.removeListener(_retire);
    for (final opening in _openings.toList()) {
      opening._supersede();
    }
  }
}

final exerciseCatalogEditingProvider = Provider<ExerciseCatalogEditing>((ref) {
  final editing = ExerciseCatalogEditing._(
    ref,
    ref.watch(localProfileGenerationProvider),
    ref.watch(exerciseRepositoryProvider),
  );
  ref.onDispose(editing._retire);
  return editing;
});

/// One fixed Add/Edit intent and original snapshot, with per-opening admission.
class ExerciseCatalogOpening extends ChangeNotifier {
  ExerciseCatalogOpening._(this._owner, this.initialExercise) {
    if (_owner._isCurrent) {
      _owner._openings.add(this);
    } else {
      _state = ExerciseCatalogEditingState.superseded;
    }
  }

  final ExerciseCatalogEditing _owner;
  final Exercise? initialExercise;
  ExerciseCatalogEditingState _state = ExerciseCatalogEditingState.idle;
  Future<ExerciseCatalogEditingState>? _pending;
  String? _validationMessage;
  bool _released = false;

  ExerciseCatalogEditingState get state => _state;
  String? get validationMessage => _validationMessage;
  String? get errorMessage => _state == ExerciseCatalogEditingState.failed
      ? 'Could not save this exercise. Please try again.'
      : null;
  bool get isCurrent =>
      !_released &&
      _state != ExerciseCatalogEditingState.superseded &&
      _owner._isCurrent;
  bool get canSubmit =>
      isCurrent &&
      (_state == ExerciseCatalogEditingState.idle ||
          _state == ExerciseCatalogEditingState.failed);

  void _supersede() {
    _state = ExerciseCatalogEditingState.superseded;
    _owner._openings.remove(this);
    // Retirement can occur during provider/widget teardown. Currency changes
    // synchronously; only presentation notification waits for a safe lifecycle.
    scheduleMicrotask(() {
      if (!_released) notifyListeners();
    });
  }

  /// Rejects future commands and late presentation, not accepted persistence.
  void release() => dispose();

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _state = ExerciseCatalogEditingState.superseded;
    _owner._openings.remove(this);
    super.dispose();
  }

  Future<ExerciseCatalogEditingState> save(ExerciseCatalogDraft draft) {
    if (!isCurrent) return Future.value(ExerciseCatalogEditingState.superseded);
    if (_pending != null) return _pending!;
    if (_state == ExerciseCatalogEditingState.succeeded) {
      return Future.value(_state);
    }
    final name = draft.name.trim();
    if (name.isEmpty) {
      _validationMessage = 'Required';
      notifyListeners();
      return Future.value(_state);
    }
    _validationMessage = null;
    final completion = Completer<ExerciseCatalogEditingState>();
    _pending = completion.future;
    _state = ExerciseCatalogEditingState.pending;
    // Claim before listeners or persistence can reenter with another draft.
    notifyListeners();
    unawaited(_persist(draft, name, completion));
    return completion.future;
  }

  Future<void> _persist(
    ExerciseCatalogDraft draft,
    String name,
    Completer<ExerciseCatalogEditingState> completion,
  ) async {
    var result = ExerciseCatalogEditingState.superseded;
    try {
      // This check follows pending notification. Submission is the acceptance
      // point; no later stage can redirect or roll back the captured write.
      if (isCurrent) {
        final notes = draft.notes?.trim();
        final normalizedNotes = notes == null || notes.isEmpty ? null : notes;
        final existing = initialExercise;
        if (existing == null) {
          await _owner._repository.create(
            name: name,
            category: draft.category,
            defaultRestSeconds: draft.defaultRestSeconds,
            loadKind: draft.loadKind,
            isUnilateral: draft.isUnilateral,
            notes: normalizedNotes,
          );
        } else {
          await _owner._repository.update(
            existing.id,
            name: name,
            category: draft.category,
            defaultRestSeconds: draft.defaultRestSeconds,
            loadKind: draft.loadKind,
            isUnilateral: draft.isUnilateral,
            notes: normalizedNotes,
          );
        }
        if (isCurrent) result = ExerciseCatalogEditingState.succeeded;
      }
    } catch (_) {
      if (isCurrent) result = ExerciseCatalogEditingState.failed;
    }
    _pending = null;
    _state = result;
    completion.complete(result);
    if (!_released) notifyListeners();
  }
}
