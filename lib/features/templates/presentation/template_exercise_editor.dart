import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/duration_format.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/rep_target.dart';
import '../domain/template_exercise_draft.dart';
import '../template_providers.dart';

/// Modal sheet to add or edit a template row. Pass [existing] to edit.
Future<void> showTemplateExerciseEditor(
  BuildContext context, {
  required String templateId,
  TemplateExercise? existing,
  String? suggestedOrderLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TemplateExerciseEditor(
      templateId: templateId,
      existing: existing,
      suggestedOrderLabel: suggestedOrderLabel,
    ),
  );
}

enum _TargetMode { reps, time }

class _TemplateExerciseEditor extends ConsumerStatefulWidget {
  const _TemplateExerciseEditor({
    required this.templateId,
    this.existing,
    this.suggestedOrderLabel,
  });

  final String templateId;
  final TemplateExercise? existing;
  final String? suggestedOrderLabel;

  @override
  ConsumerState<_TemplateExerciseEditor> createState() =>
      _TemplateExerciseEditorState();
}

class _TemplateExerciseEditorState
    extends ConsumerState<_TemplateExerciseEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _order;
  late final TextEditingController _name;
  late final TextEditingController _sets;
  late final TextEditingController _min;
  late final TextEditingController _max;
  late final TextEditingController _rest;
  late final TextEditingController _notes;
  late _TargetMode _mode;
  late LoadKind _loadKind;
  late bool _isUnilateral;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final usesTime = (e?.durationMinSeconds ?? e?.durationMaxSeconds) != null;
    _mode = usesTime ? _TargetMode.time : _TargetMode.reps;
    _order = TextEditingController(
      text: e?.orderLabel ?? widget.suggestedOrderLabel ?? '',
    );
    _name = TextEditingController(text: e?.displayName ?? '');
    _sets = TextEditingController(text: '${e?.targetSets ?? 3}');
    _min = TextEditingController(
      text: usesTime
          ? (e?.durationMinSeconds?.toString() ?? '')
          : (e?.repMin?.toString() ?? ''),
    );
    _max = TextEditingController(
      text: usesTime
          ? (e?.durationMaxSeconds?.toString() ?? '')
          : (e?.repMax?.toString() ?? ''),
    );
    _rest = TextEditingController(
      text: Duration(seconds: e?.restSeconds ?? 120).restLabel,
    );
    _notes = TextEditingController(text: e?.notes ?? '');
    _loadKind = e?.loadKind ?? LoadKind.externalWeight;
    _isUnilateral = e?.isUnilateral ?? false;
  }

  @override
  void dispose() {
    for (final c in [_order, _name, _sets, _min, _max, _rest, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  RepTarget _buildTarget() {
    final min = int.tryParse(_min.text.trim());
    final max = int.tryParse(_max.text.trim());
    if (min == null && max == null) return RepTarget.none;
    return switch (_mode) {
      _TargetMode.reps => RepTarget(repMin: min, repMax: max ?? min),
      _TargetMode.time => RepTarget(
          durationMin: min == null ? null : Duration(seconds: min),
          durationMax: Duration(seconds: max ?? min!),
        ),
    };
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = ref.read(templateRepositoryProvider);
    final draft = TemplateExerciseDraft(
      displayName: _name.text.trim(),
      orderLabel: _order.text.trim(),
      targetSets: int.tryParse(_sets.text.trim()) ?? 3,
      repTarget: _buildTarget(),
      restSeconds:
          (parseRest(_rest.text) ?? const Duration(seconds: 120)).inSeconds,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      isUnilateral: _isUnilateral,
      loadKind: _loadKind,
    );
    if (_isEditing) {
      await repo.updateExercise(widget.existing!.id, widget.templateId, draft);
    } else {
      await repo.addExercise(widget.templateId, draft);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final isReps = _mode == _TargetMode.reps;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _isEditing ? 'Edit exercise row' : 'Add exercise row',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: TextFormField(
                      controller: _order,
                      decoration: const InputDecoration(
                        labelText: 'Order',
                        hintText: '2A',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Req.' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _name,
                      autofocus: !_isEditing,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Exercise'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: TextFormField(
                      controller: _sets,
                      decoration: const InputDecoration(labelText: 'Sets'),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _rest,
                      decoration: const InputDecoration(
                        labelText: 'Rest',
                        hintText: "90s, 2'",
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SegmentedButton<_TargetMode>(
                segments: const [
                  ButtonSegment(value: _TargetMode.reps, label: Text('Reps')),
                  ButtonSegment(value: _TargetMode.time, label: Text('Time (s)')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _min,
                      decoration: InputDecoration(
                        labelText: isReps ? 'Min reps' : 'Min sec',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _max,
                      decoration: InputDecoration(
                        labelText: isReps ? 'Max reps' : 'Max sec',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<LoadKind>(
                initialValue: _loadKind,
                decoration: const InputDecoration(labelText: 'Load'),
                items: [
                  for (final k in LoadKind.values)
                    DropdownMenuItem(value: k, child: Text(k.label)),
                ],
                onChanged: (v) => setState(() => _loadKind = v ?? _loadKind),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Unilateral (left/right)'),
                value: _isUnilateral,
                onChanged: (v) => setState(() => _isUnilateral = v),
              ),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'bench 8, pause, etc.',
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _save,
                child: Text(_isEditing ? 'Save row' : 'Add row'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
