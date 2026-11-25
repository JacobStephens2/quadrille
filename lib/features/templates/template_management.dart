import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/retained_opening.dart';
import 'data/template_repository.dart';
import 'template_providers.dart';

enum TemplateManagementState { idle, pending, succeeded, failed, superseded }

enum TemplateManagementAction { create, rename, duplicate, archive }

/// Capture from the rendering scope before opening a dialog or menu.
/// Retirement rejects new submissions; accepted persistence keeps this repository.
class TemplateManagement {
  TemplateManagement._(this._owner, this._repository);

  final RetainedOpeningOwner _owner;
  final TemplateRepository _repository;

  TemplateManagementOpening create() => TemplateManagementOpening._(
    _owner,
    _repository,
    TemplateManagementAction.create,
  );

  TemplateManagementOpening rename(String id, String sourceName) =>
      TemplateManagementOpening._(
        _owner,
        _repository,
        TemplateManagementAction.rename,
        targetId: id,
        sourceName: sourceName,
      );

  TemplateManagementOpening duplicate(String id, String sourceName) =>
      TemplateManagementOpening._(
        _owner,
        _repository,
        TemplateManagementAction.duplicate,
        targetId: id,
        sourceName: sourceName,
      );

  TemplateManagementOpening archive(String id) => TemplateManagementOpening._(
    _owner,
    _repository,
    TemplateManagementAction.archive,
    targetId: id,
  );
}

final templateManagementProvider = Provider<TemplateManagement>((ref) {
  final generation = ref.watch(localProfileGenerationProvider);
  final repository = ref.watch(templateRepositoryProvider);
  return TemplateManagement._(
    RetainedOpeningOwner(
      ref,
      generation,
      destinations: [
        RetainedDestination(
          repository,
          () => ref.read(templateRepositoryProvider),
        ),
      ],
    ),
    repository,
  );
});

/// A fixed intent and target, with observable admission, retry and retirement.
/// Only create/rename accept editable names. Successful openings are single-use.
class TemplateManagementOpening
    extends RetainedOpening<TemplateManagementState> {
  TemplateManagementOpening._(
    super.owner,
    this._repository,
    this.action, {
    this.targetId,
    this.sourceName = '',
  }) : super(
         idle: TemplateManagementState.idle,
         pending: TemplateManagementState.pending,
         failed: TemplateManagementState.failed,
         superseded: TemplateManagementState.superseded,
       );

  final TemplateRepository _repository;
  final TemplateManagementAction action;
  final String? targetId;
  final String sourceName;
  String? _resultId;
  String? _name;
  bool _blankName = false;

  String? get resultId => _resultId;
  String get name => _name ?? sourceName;
  bool get requiresName =>
      action == TemplateManagementAction.create ||
      action == TemplateManagementAction.rename;
  String? get errorMessage => state != TemplateManagementState.failed
      ? null
      : _blankName
      ? 'Name is required'
      : 'Could not ${action.name} template. Please try again.';

  Future<TemplateManagementState> submit({String? name}) {
    final normalized = (name ?? this.name).trim();
    // Validation and name retention only at admission: a pending or
    // succeeded opening returns its claimed result and a non-current one
    // returns superseded, each without disturbing the retained name.
    if (canSubmit) {
      if (requiresName && normalized.isEmpty) {
        _blankName = true;
        return Future.value(failWithoutPersisting());
      }
      _blankName = false;
      if (requiresName) _name = normalized;
    }
    return submitPersistence<String>(
      () => _persist(normalized),
      mapCompleted: (id) {
        _resultId = id;
        return TemplateManagementState.succeeded;
      },
      // Duplicate/archive are fixed writes: concurrent openings for the
      // same target share one persistence call through the owner.
      sharingKey: requiresName ? null : (action, targetId),
    );
  }

  Future<String> _persist(String normalized) async {
    switch (action) {
      case TemplateManagementAction.create:
        return _repository.createTemplate(name: normalized);
      case TemplateManagementAction.rename:
        await _repository.updateTemplate(targetId!, name: normalized);
        return targetId!;
      case TemplateManagementAction.duplicate:
        return _repository.duplicateTemplate(
          targetId!,
          newName: '$sourceName (copy)',
        );
      case TemplateManagementAction.archive:
        await _repository.archiveTemplate(targetId!);
        return targetId!;
    }
  }
}
