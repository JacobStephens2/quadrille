import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:countdown_ring/countdown_ring.dart';
import '../../../core/domain/enums.dart';
import '../exercise_catalog_editing.dart';

/// Modal sheet for one catalog opening captured by its rendering screen.
Future<void> showExerciseEditor(
  BuildContext context, {
  required ExerciseCatalogOpening opening,
}) async {
  try {
    final presentation = _Presentation(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _ExerciseEditor(opening: opening, presentation: presentation),
    );
  } finally {
    opening.release();
  }
}

/// Visibility includes enclosing routes: a branch can remain current beneath a
/// root dialog, or remain mounted while its stateful tab is inactive.
class _Presentation {
  _Presentation(this.context)
    : routes = _invokingRoutes(context),
      router = GoRouter.maybeOf(context),
      location = GoRouter.maybeOf(context)?.routeInformationProvider.value.uri;

  final BuildContext context;
  final List<ModalRoute<dynamic>> routes;
  final GoRouter? router;
  final Uri? location;

  bool get isVisible =>
      context.mounted &&
      routes.isNotEmpty &&
      routes.every((route) => route.isActive) &&
      routes.skip(1).every((route) => route.isCurrent) &&
      TickerMode.valuesOf(context).enabled &&
      (router == null ||
          router!.routeInformationProvider.value.uri == location);

  static List<ModalRoute<dynamic>> _invokingRoutes(BuildContext context) {
    final routes = <ModalRoute<dynamic>>[];
    BuildContext? scope = context;
    while (scope != null) {
      final route = ModalRoute.of(scope);
      if (route != null) routes.add(route);
      scope = scope.findAncestorStateOfType<NavigatorState>()?.context;
    }
    return routes;
  }
}

class _ExerciseEditor extends StatefulWidget {
  const _ExerciseEditor({required this.opening, required this.presentation});

  final ExerciseCatalogOpening opening;
  final _Presentation presentation;

  @override
  State<_ExerciseEditor> createState() => _ExerciseEditorState();
}

class _ExerciseEditorState extends State<_ExerciseEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _rest;
  late final TextEditingController _notes;
  late ExerciseCategory _category;
  late LoadKind _loadKind;
  late bool _isUnilateral;
  bool _silent = false;

  bool get _isEditing => widget.opening.initialExercise != null;

  @override
  void initState() {
    super.initState();
    final e = widget.opening.initialExercise;
    _name = TextEditingController(text: e?.name ?? '');
    _rest = TextEditingController(
      text: Duration(seconds: e?.defaultRestSeconds ?? 120).compactLabel,
    );
    _notes = TextEditingController(text: e?.notes ?? '');
    _category = e?.category ?? ExerciseCategory.other;
    _loadKind = e?.loadKind ?? LoadKind.externalWeight;
    _isUnilateral = e?.isUnilateral ?? false;
  }

  @override
  void dispose() {
    widget.opening.release();
    _name.dispose();
    _rest.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!widget.opening.canSubmit) return;
    if (!_formKey.currentState!.validate()) return;
    final rest = parseDuration(_rest.text) ?? const Duration(seconds: 120);
    setState(() => _silent = false);
    final result = await widget.opening.save(
      ExerciseCatalogDraft(
        name: _name.text,
        category: _category,
        defaultRestSeconds: rest.inSeconds,
        loadKind: _loadKind,
        isUnilateral: _isUnilateral,
        notes: _notes.text,
      ),
    );
    if (!mounted) return;
    if (!widget.presentation.isVisible ||
        ModalRoute.of(context)?.isCurrent != true) {
      // A completion observed while covered stays silent after uncovering.
      setState(() => _silent = true);
      return;
    }
    if (widget.opening.isCurrent &&
        result == ExerciseCatalogEditingState.succeeded) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ListenableBuilder(
      listenable: widget.opening,
      builder: (context, _) {
        final opening = widget.opening;
        final enabled = opening.canSubmit;
        final obsolete = !opening.isCurrent;
        return SingleChildScrollView(
          child: Padding(
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
                    enabled: enabled,
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
                    onChanged: enabled
                        ? (v) => setState(() => _category = v ?? _category)
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          enabled: enabled,
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
                          onChanged: enabled
                              ? (v) =>
                                    setState(() => _loadKind = v ?? _loadKind)
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Unilateral (left/right)'),
                    value: _isUnilateral,
                    onChanged: enabled
                        ? (v) => setState(() => _isUnilateral = v)
                        : null,
                  ),
                  TextFormField(
                    enabled: enabled,
                    controller: _notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                    minLines: 1,
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),
                  if (opening.state == ExerciseCatalogEditingState.pending)
                    const LinearProgressIndicator(),
                  if (obsolete)
                    const Text(
                      'This editor is no longer current. Close and reopen it.',
                    ),
                  if (!_silent && opening.errorMessage != null)
                    Text(opening.errorMessage!),
                  FilledButton(
                    onPressed: enabled ? _save : null,
                    child: Text(_isEditing ? 'Save' : 'Add exercise'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(obsolete ? 'Close' : 'Cancel'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
