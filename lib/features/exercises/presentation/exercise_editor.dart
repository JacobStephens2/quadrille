import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/duration_format.dart';
import '../../../core/domain/enums.dart';
import '../exercise_providers.dart';

/// Modal sheet to create or edit a catalog [Exercise]. Pass [existing] to edit.
Future<void> showExerciseEditor(
  BuildContext context, {
  Exercise? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ExerciseEditor(existing: existing),
  );
}

class ExerciseEditor extends ConsumerStatefulWidget {
  const ExerciseEditor({super.key, this.existing});

  final Exercise? existing;

  @override
  ConsumerState<ExerciseEditor> createState() => _ExerciseEditorState();
}

class _ExerciseEditorState extends ConsumerState<ExerciseEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _rest;
  late final TextEditingController _notes;
  late ExerciseCategory _category;
  late LoadKind _loadKind;
  late bool _isUnilateral;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _rest = TextEditingController(
      text: Duration(seconds: e?.defaultRestSeconds ?? 120).restLabel,
    );
    _notes = TextEditingController(text: e?.notes ?? '');
    _category = e?.category ?? ExerciseCategory.other;
    _loadKind = e?.loadKind ?? LoadKind.externalWeight;
    _isUnilateral = e?.isUnilateral ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _rest.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = ref.read(exerciseRepositoryProvider);
    final rest = parseRest(_rest.text) ?? const Duration(seconds: 120);
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
    if (_isEditing) {
      await repo.update(
        widget.existing!.id,
        name: _name.text.trim(),
        category: _category,
        defaultRestSeconds: rest.inSeconds,
        loadKind: _loadKind,
        isUnilateral: _isUnilateral,
        notes: notes,
      );
    } else {
      await repo.create(
        name: _name.text.trim(),
        category: _category,
        defaultRestSeconds: rest.inSeconds,
        loadKind: _loadKind,
        isUnilateral: _isUnilateral,
        notes: notes,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isEditing ? 'Edit exercise' : 'New exercise',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              autofocus: !_isEditing,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ExerciseCategory>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final c in ExerciseCategory.values)
                  DropdownMenuItem(value: c, child: Text(c.label)),
              ],
              onChanged: (v) => setState(() => _category = v ?? _category),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _rest,
                    decoration: const InputDecoration(
                      labelText: 'Default rest',
                      hintText: "90s, 2', 1:30",
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<LoadKind>(
                    initialValue: _loadKind,
                    decoration: const InputDecoration(labelText: 'Load'),
                    items: [
                      for (final k in LoadKind.values)
                        DropdownMenuItem(value: k, child: Text(k.label)),
                    ],
                    onChanged: (v) => setState(() => _loadKind = v ?? _loadKind),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Unilateral (left/right)'),
              value: _isUnilateral,
              onChanged: (v) => setState(() => _isUnilateral = v),
            ),
            TextFormField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _save,
              child: Text(_isEditing ? 'Save' : 'Add exercise'),
            ),
          ],
        ),
      ),
    );
  }
}
