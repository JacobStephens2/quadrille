import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
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

/// Capture from the rendering scope, before binding any editor or confirmation.
/// This owner outlives screen subscriptions, but never its captured repositories.
class TemplateExerciseEditing {
  TemplateExerciseEditing._(
    this._ref,
    this._generation,
    this._templates,
    this._catalog,
  ) {
    _generation.addListener(_retire);
  }

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final TemplateRepository _templates;
  final ExerciseRepository _catalog;
  final _openings = <TemplateExerciseOpening>{};
  bool _active = true;

  bool get _isCurrent {
    if (!_active) return false;
    if (!_ref.mounted ||
        !_generation.isCurrent ||
        !identical(_templates, _ref.read(templateRepositoryProvider)) ||
        !identical(_catalog, _ref.read(exerciseRepositoryProvider))) {
      _retire();
    }
    return _active;
  }

  TemplateExerciseEditorOpening edit(String templateId, {String? rowId}) =>
      TemplateExerciseEditorOpening._(this, templateId, rowId);

  TemplateExerciseDeletionOpening deletion(String templateId, String rowId) =>
      TemplateExerciseDeletionOpening._(this, templateId, rowId);

  void _retire() {
    if (!_active) return;
    _active = false;
    _generation.removeListener(_retire);
    for (final opening in _openings.toList()) {
      opening._supersede();
    }
  }
}

final templateExerciseEditingProvider = Provider<TemplateExerciseEditing>((
  ref,
) {
  final editing = TemplateExerciseEditing._(
    ref,
    ref.watch(localProfileGenerationProvider),
    ref.watch(templateRepositoryProvider),
    ref.watch(exerciseRepositoryProvider),
  );
  ref.onDispose(editing._retire);
  return editing;
});

/// One fixed target, with shared pending, retry and obsolete-result policy.
sealed class TemplateExerciseOpening extends ChangeNotifier {
  TemplateExerciseOpening._(this._owner, this.templateId) {
    if (_owner._isCurrent) {
      _owner._openings.add(this);
    } else {
      _state = TemplateExerciseEditingState.superseded;
    }
  }

  final TemplateExerciseEditing _owner;
  final String templateId;
  TemplateExerciseEditingState _state = TemplateExerciseEditingState.idle;
  Future<TemplateExerciseEditingState>? _pending;
  bool _released = false;

  TemplateExerciseEditingState get state => _state;
  bool get isCurrent =>
      !_released &&
      _state != TemplateExerciseEditingState.superseded &&
      _owner._isCurrent;
  bool get canSubmit =>
      isCurrent &&
      (_state == TemplateExerciseEditingState.idle ||
          _state == TemplateExerciseEditingState.failed);

  void _stopObserving() {}

  void _supersede() {
    _state = TemplateExerciseEditingState.superseded;
    _stopObserving();
    _owner._openings.remove(this);
    // Retirement can run during Riverpod disposal or a widget build. State is
    // obsolete synchronously; presentation notification follows that lifecycle.
    scheduleMicrotask(() {
      if (!_released) notifyListeners();
    });
  }

  /// Stops new commands and observation, without cancelling accepted persistence.
  void release() => dispose();

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _state = TemplateExerciseEditingState.superseded;
    _stopObserving();
    _owner._openings.remove(this);
    super.dispose();
  }

  Future<TemplateExerciseEditingState> _submit(
    Future<void> Function() persist,
  ) {
    if (!isCurrent) {
      return Future.value(TemplateExerciseEditingState.superseded);
    }
    if (_pending != null) return _pending!;
    if (_state == TemplateExerciseEditingState.succeeded) {
      return Future.value(_state);
    }
    final completion = Completer<TemplateExerciseEditingState>();
    _pending = completion.future;
    _state = TemplateExerciseEditingState.pending;
    // Claim pending before notifying: even a reentrant listener shares this call.
    notifyListeners();
    unawaited(_persist(persist, completion));
    return completion.future;
  }

  Future<void> _persist(
    Future<void> Function() persist,
    Completer<TemplateExerciseEditingState> completion,
  ) async {
    var result = TemplateExerciseEditingState.superseded;
    try {
      if (isCurrent) {
        await persist();
        if (isCurrent) result = TemplateExerciseEditingState.succeeded;
      }
    } catch (_) {
      if (isCurrent) result = TemplateExerciseEditingState.failed;
    }
    _pending = null;
    _state = result;
    completion.complete(result);
    if (!_released) notifyListeners();
  }
}

class TemplateExerciseEditorOpening extends TemplateExerciseOpening {
  TemplateExerciseEditorOpening._(super.owner, super.templateId, this._rowId)
    : super._() {
    if (!isCurrent) {
      _supersede();
      return;
    }
    _subscription = _owner._catalog.watchAll().listen(
      (exercises) {
        if (!isCurrent) return;
        _suggestions = List.unmodifiable(exercises);
        notifyListeners();
      },
      onError: (Object error, StackTrace stack) {
        // Catalog errors do not prevent free-text editing. Retirement wins over
        // late errors and emissions from this captured subscription.
        if (!isCurrent) return;
      },
    );
  }

  final String? _rowId;
  StreamSubscription<List<Exercise>>? _subscription;
  List<Exercise> _suggestions = const [];

  List<Exercise> get suggestions => isCurrent ? _suggestions : const [];

  Future<TemplateExerciseEditingState> save(TemplateExerciseDraft draft) =>
      _submit(() async {
        if (_rowId == null) {
          await _owner._templates.addExercise(templateId, draft);
        } else {
          await _owner._templates.updateExercise(_rowId, templateId, draft);
        }
      });

  @override
  void _stopObserving() {
    final subscription = _subscription;
    _subscription = null;
    _suggestions = const [];
    if (subscription != null) unawaited(subscription.cancel());
  }
}

class TemplateExerciseDeletionOpening extends TemplateExerciseOpening {
  TemplateExerciseDeletionOpening._(super.owner, super.templateId, this._rowId)
    : super._();

  final String _rowId;

  Future<TemplateExerciseEditingState> delete() =>
      _submit(() => _owner._templates.deleteExercise(_rowId));
}
