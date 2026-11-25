import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import '../../core/retained_opening.dart';
import '../exercises/data/exercise_repository.dart';
import '../exercises/exercise_providers.dart';
import 'data/template_repository.dart';
import 'domain/template_exercise_draft.dart';
import 'template_providers.dart';

enum TemplateExerciseEditingState {
  idle,
  pending,
  succeeded,
  failed,
  superseded,
}

/// Retains the invoking Local profile generation and its exact template and
/// catalog destinations. Capture from the rendering scope, before binding
/// any editor or confirmation; this owner outlives screen subscriptions,
/// but never its captured repositories.
class TemplateExerciseEditing {
  TemplateExerciseEditing._(this._owner, this._templates, this._catalog);

  final RetainedOpeningOwner _owner;
  final TemplateRepository _templates;
  final ExerciseRepository _catalog;

  TemplateExerciseEditorOpening edit(String templateId, {String? rowId}) =>
      TemplateExerciseEditorOpening._(
        _owner,
        _templates,
        _catalog,
        templateId,
        rowId,
      );

  TemplateExerciseDeletionOpening deletion(String templateId, String rowId) =>
      TemplateExerciseDeletionOpening._(_owner, _templates, templateId, rowId);
}

final templateExerciseEditingProvider = Provider<TemplateExerciseEditing>((
  ref,
) {
  final generation = ref.watch(localProfileGenerationProvider);
  final templates = ref.watch(templateRepositoryProvider);
  final catalog = ref.watch(exerciseRepositoryProvider);
  return TemplateExerciseEditing._(
    RetainedOpeningOwner(
      ref,
      generation,
      destinations: [
        RetainedDestination(
          templates,
          () => ref.read(templateRepositoryProvider),
        ),
        RetainedDestination(
          catalog,
          () => ref.read(exerciseRepositoryProvider),
        ),
      ],
    ),
    templates,
    catalog,
  );
});

/// One fixed template row editor, with live catalog suggestions while current.
class TemplateExerciseEditorOpening
    extends RetainedOpening<TemplateExerciseEditingState> {
  TemplateExerciseEditorOpening._(
    super.owner,
    this._templates,
    this._catalog,
    this.templateId,
    this._rowId,
  ) : super(
        idle: TemplateExerciseEditingState.idle,
        pending: TemplateExerciseEditingState.pending,
        failed: TemplateExerciseEditingState.failed,
        superseded: TemplateExerciseEditingState.superseded,
      ) {
    if (!isCurrent) return;
    _subscription = _catalog.watchAll().listen(
      (exercises) {
        if (!isCurrent) return;
        _suggestions = List.unmodifiable(exercises);
        notifyListeners();
      },
      onError: (Object error, StackTrace stack) {
        // Catalog errors do not prevent free-text editing. Retirement wins
        // over late errors and emissions from this captured subscription.
        if (!isCurrent) return;
      },
    );
  }

  final TemplateRepository _templates;
  final ExerciseRepository _catalog;
  final String templateId;
  final String? _rowId;
  StreamSubscription<List<Exercise>>? _subscription;
  List<Exercise> _suggestions = const [];

  List<Exercise> get suggestions => isCurrent ? _suggestions : const [];

  Future<TemplateExerciseEditingState> save(TemplateExerciseDraft draft) =>
      submit(() async {
        if (_rowId == null) {
          await _templates.addExercise(templateId, draft);
        } else {
          await _templates.updateExercise(_rowId, templateId, draft);
        }
      }, mapCompleted: (_) => TemplateExerciseEditingState.succeeded);

  @override
  void onRetired() {
    final subscription = _subscription;
    _subscription = null;
    _suggestions = const [];
    if (subscription != null) unawaited(subscription.cancel());
  }
}

/// One fixed template row deletion confirmation.
class TemplateExerciseDeletionOpening
    extends RetainedOpening<TemplateExerciseEditingState> {
  TemplateExerciseDeletionOpening._(
    super.owner,
    this._templates,
    this.templateId,
    this._rowId,
  ) : super(
        idle: TemplateExerciseEditingState.idle,
        pending: TemplateExerciseEditingState.pending,
        failed: TemplateExerciseEditingState.failed,
        superseded: TemplateExerciseEditingState.superseded,
      );

  final TemplateRepository _templates;
  final String templateId;
  final String _rowId;

  Future<TemplateExerciseEditingState> delete() => submit(
    () => _templates.deleteExercise(_rowId),
    mapCompleted: (_) => TemplateExerciseEditingState.succeeded,
  );
}
