import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'data/template_repository.dart';
import 'template_providers.dart';

enum TemplateManagementState { idle, pending, succeeded, failed, superseded }

enum TemplateManagementAction { create, rename, duplicate, archive }

/// Capture from the rendering scope before opening a dialog or menu.
/// Retirement rejects new submissions; accepted persistence keeps this repository.
class TemplateManagement {
  TemplateManagement._(this._ref, this._generation, this._repository) {
    _generation.addListener(_retire);
  }

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final TemplateRepository _repository;
  final _openings = <TemplateManagementOpening>{};
  final _immediate = <(TemplateManagementAction, String?), _Submission>{};
  bool _active = true;

  bool get _isCurrent {
    if (!_active) return false;
    if (!_ref.mounted ||
        !_generation.isCurrent ||
        !identical(_repository, _ref.read(templateRepositoryProvider))) {
      _retire();
    }
    return _active;
  }

  TemplateManagementOpening create() =>
      TemplateManagementOpening._(this, TemplateManagementAction.create);

  TemplateManagementOpening rename(String id, String sourceName) =>
      TemplateManagementOpening._(
        this,
        TemplateManagementAction.rename,
        targetId: id,
        sourceName: sourceName,
      );

  TemplateManagementOpening duplicate(String id, String sourceName) =>
      TemplateManagementOpening._(
        this,
        TemplateManagementAction.duplicate,
        targetId: id,
        sourceName: sourceName,
      );

  TemplateManagementOpening archive(String id) => TemplateManagementOpening._(
    this,
    TemplateManagementAction.archive,
    targetId: id,
  );

  void _retire() {
    if (!_active) return;
    _active = false;
    _generation.removeListener(_retire);
    for (final opening in _openings.toList()) {
      opening._supersede();
    }
  }

  Future<void> _persist(
    TemplateManagementOpening opening,
    String name,
    _Submission submission,
  ) async {
    var result = const _Result(TemplateManagementState.superseded);
    try {
      // This call is the acceptance point. No later stage consults a new owner.
      if (opening.isCurrent) {
        final id = switch (opening.action) {
          TemplateManagementAction.create => await _repository.createTemplate(
            name: name,
          ),
          TemplateManagementAction.rename => await (() async {
            await _repository.updateTemplate(opening.targetId!, name: name);
            return opening.targetId;
          })(),
          TemplateManagementAction.duplicate =>
            await _repository.duplicateTemplate(
              opening.targetId!,
              newName: '${opening.sourceName} (copy)',
            ),
          TemplateManagementAction.archive => await (() async {
            await _repository.archiveTemplate(opening.targetId!);
            return opening.targetId;
          })(),
        };
        result = _Result(TemplateManagementState.succeeded, id);
      }
    } catch (_) {
      result = const _Result(TemplateManagementState.failed);
    }
    final key = opening._sharingKey;
    if (key != null && identical(_immediate[key], submission)) {
      _immediate.remove(key);
    }
    submission.completion.complete(result);
  }
}

final templateManagementProvider = Provider<TemplateManagement>((ref) {
  final management = TemplateManagement._(
    ref,
    ref.watch(localProfileGenerationProvider),
    ref.watch(templateRepositoryProvider),
  );
  ref.onDispose(management._retire);
  return management;
});

/// A fixed intent and target, with observable admission, retry and retirement.
/// Only create/rename accept editable names. Successful openings are single-use.
class TemplateManagementOpening extends ChangeNotifier {
  TemplateManagementOpening._(
    this._owner,
    this.action, {
    this.targetId,
    this.sourceName = '',
  }) {
    if (_owner._isCurrent) {
      _owner._openings.add(this);
    } else {
      _state = TemplateManagementState.superseded;
    }
  }

  final TemplateManagement _owner;
  final TemplateManagementAction action;
  final String? targetId;
  final String sourceName;
  TemplateManagementState _state = TemplateManagementState.idle;
  Future<TemplateManagementState>? _pending;
  bool _released = false;
  String? _resultId;
  String? _name;
  bool _blankName = false;

  TemplateManagementState get state => _state;
  String? get resultId => _resultId;
  String get name => _name ?? sourceName;
  bool get requiresName =>
      action == TemplateManagementAction.create ||
      action == TemplateManagementAction.rename;
  bool get isCurrent =>
      !_released &&
      _state != TemplateManagementState.superseded &&
      _owner._isCurrent;
  bool get canSubmit =>
      isCurrent &&
      (_state == TemplateManagementState.idle ||
          _state == TemplateManagementState.failed);
  String? get errorMessage => _state != TemplateManagementState.failed
      ? null
      : _blankName
      ? 'Name is required'
      : 'Could not ${action.name} template. Please try again.';

  (TemplateManagementAction, String?)? get _sharingKey =>
      requiresName ? null : (action, targetId);

  void _supersede() {
    _state = TemplateManagementState.superseded;
    _owner._openings.remove(this);
    // State retires synchronously. Notify outside provider/widget disposal.
    scheduleMicrotask(() {
      if (!_released) notifyListeners();
    });
  }

  /// Release observation and new commands, without cancelling accepted writes.
  void release() => dispose();

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _state = TemplateManagementState.superseded;
    _owner._openings.remove(this);
    super.dispose();
  }

  Future<TemplateManagementState> submit({String? name}) {
    if (_pending != null) return _pending!;
    if (!isCurrent) return Future.value(TemplateManagementState.superseded);
    if (_state == TemplateManagementState.succeeded) {
      return Future.value(_state);
    }
    final normalized = (name ?? this.name).trim();
    if (requiresName && normalized.isEmpty) {
      _blankName = true;
      _state = TemplateManagementState.failed;
      notifyListeners();
      return Future.value(_state);
    }
    _blankName = false;
    if (requiresName) _name = normalized;
    final completion = Completer<TemplateManagementState>();
    _pending = completion.future;
    _state = TemplateManagementState.pending;
    final key = _sharingKey;
    final shared = key == null ? null : _owner._immediate[key];
    final submission = shared ?? _Submission();
    if (key != null) _owner._immediate[key] = submission;
    // Claim both the opening and shared operation before listeners can reenter.
    notifyListeners();
    if (shared == null) {
      unawaited(_owner._persist(this, normalized, submission));
    }
    unawaited(_finish(submission, completion));
    return completion.future;
  }

  Future<void> _finish(
    _Submission submission,
    Completer<TemplateManagementState> completion,
  ) async {
    final result = await submission.completion.future;
    _state = isCurrent ? result.state : TemplateManagementState.superseded;
    if (_state == TemplateManagementState.succeeded) _resultId = result.id;
    _pending = null;
    completion.complete(_state);
    if (!_released) notifyListeners();
  }
}

class _Submission {
  final completion = Completer<_Result>();
}

class _Result {
  const _Result(this.state, [this.id]);
  final TemplateManagementState state;
  final String? id;
}
