import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../template_management.dart';

/// The invoking screen, route and location must still be visible at completion.
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
      TickerMode.valuesOf(context).enabled &&
      (router == null ||
          router!.routeInformationProvider.value.uri == location);

  bool get isCurrent => isVisible && routes.every((route) => route.isCurrent);

  static List<ModalRoute<dynamic>> _invokingRoutes(BuildContext context) {
    final routes = <ModalRoute<dynamic>>[];
    BuildContext? scope = context;
    while (scope != null) {
      final route = ModalRoute.of(scope);
      if (route != null) routes.add(route);
      // A tab's inner route can stay current beneath a root-navigator dialog.
      // Its navigator's context belongs to the enclosing route's scope.
      scope = scope.findAncestorStateOfType<NavigatorState>()?.context;
    }
    return routes;
  }
}

Future<void> showTemplateName(
  BuildContext context,
  TemplateManagementOpening opening,
) => _showName(_Presentation(context), opening);

Future<void> _showName(
  _Presentation presentation,
  TemplateManagementOpening opening,
) async {
  final screenContext = presentation.context;
  try {
    final saved = await showDialog<bool>(
      context: screenContext,
      builder: (_) => _NameDialog(opening: opening, presentation: presentation),
    );
    if (saved == true &&
        screenContext.mounted &&
        opening.isCurrent &&
        presentation.isCurrent &&
        opening.action == TemplateManagementAction.create) {
      screenContext.go('/templates/${opening.resultId}');
    }
  } finally {
    opening.release();
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.opening, required this.presentation});
  final TemplateManagementOpening opening;
  final _Presentation presentation;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.opening.name);
  bool _required = false;
  bool _silent = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!widget.opening.canSubmit) return;
    if (_controller.text.trim().isEmpty) {
      setState(() => _required = true);
      return;
    }
    setState(() {
      _required = false;
      _silent = false;
    });
    final result = await widget.opening.submit(name: _controller.text);
    if (!mounted) return;
    if (!widget.presentation.isVisible ||
        ModalRoute.of(context)?.isCurrent != true) {
      // Keep covered forms in place; don't publish late feedback on uncovering.
      setState(() => _silent = true);
      return;
    }
    if (widget.opening.isCurrent &&
        result == TemplateManagementState.succeeded) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.opening,
    builder: (context, _) {
      final opening = widget.opening;
      final creating = opening.action == TemplateManagementAction.create;
      final pending = opening.state == TemplateManagementState.pending;
      final obsolete = opening.state == TemplateManagementState.superseded;
      return AlertDialog(
        title: Text(creating ? 'New template' : 'Rename template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: opening.canSubmit,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: creating ? 'Day 1 Push A' : null,
                errorText: _required ? 'Name is required' : null,
              ),
              onSubmitted: (_) => _save(),
            ),
            if (pending) const LinearProgressIndicator(),
            if (!_silent && opening.errorMessage != null)
              Text(opening.errorMessage!),
            if (obsolete)
              const Text(
                'This dialog is no longer current. Close and reopen it.',
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(obsolete ? 'Close' : 'Cancel'),
          ),
          FilledButton(
            onPressed: opening.canSubmit ? _save : null,
            child: Text(creating ? 'Create' : 'Save'),
          ),
        ],
      );
    },
  );
}

/// Menu item values are retained openings, never a lookup of the later profile.
class TemplateManagementMenu extends StatefulWidget {
  const TemplateManagementMenu({
    super.key,
    required this.management,
    required this.templateId,
    required this.name,
  });
  final TemplateManagement management;
  final String templateId;
  final String name;

  @override
  State<TemplateManagementMenu> createState() => _TemplateManagementMenuState();
}

class _TemplateManagementMenuState extends State<TemplateManagementMenu> {
  List<TemplateManagementOpening> _menu = [];
  TemplateManagementOpening? _active;
  _Presentation? _presentation;

  void _changed() {
    if (mounted) setState(() {});
  }

  void _releaseMenu({TemplateManagementOpening? except}) {
    for (final opening in _menu) {
      if (!identical(opening, except)) opening.release();
    }
    _menu = [];
  }

  @override
  void dispose() {
    _releaseMenu();
    _active?.removeListener(_changed);
    _active?.release();
    super.dispose();
  }

  Future<void> _select(TemplateManagementOpening opening) async {
    _releaseMenu(except: opening);
    if (!mounted) {
      opening.release();
      return;
    }
    final presentation = _presentation!;
    if (opening.requiresName) {
      await _showName(presentation, opening);
    } else {
      if (!identical(_active, opening)) {
        _active?.removeListener(_changed);
        _active?.release();
        _active = opening..addListener(_changed);
      }
      await _run(opening, presentation);
    }
  }

  Future<void> _run(
    TemplateManagementOpening opening,
    _Presentation presentation,
  ) async {
    final screenContext = presentation.context;
    if (!mounted || !presentation.isCurrent) {
      opening.release();
      return;
    }
    final result = await opening.submit();
    if (!mounted ||
        !screenContext.mounted ||
        !opening.isCurrent ||
        !presentation.isCurrent) {
      return;
    }
    if (result == TemplateManagementState.succeeded) {
      screenContext.go(
        opening.action == TemplateManagementAction.archive
            ? '/templates'
            : '/templates/${opening.resultId}',
      );
    } else if (result == TemplateManagementState.failed) {
      ScaffoldMessenger.of(screenContext).showSnackBar(
        SnackBar(
          content: Text(opening.errorMessage!),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _run(opening, presentation),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) =>
      PopupMenuButton<TemplateManagementOpening>(
        enabled: _active?.state != TemplateManagementState.pending,
        icon: _active?.state == TemplateManagementState.pending
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.more_vert),
        onCanceled: _releaseMenu,
        onSelected: _select,
        itemBuilder: (_) {
          _releaseMenu();
          _presentation = _Presentation(context);
          _menu = [
            widget.management.rename(widget.templateId, widget.name),
            widget.management.duplicate(widget.templateId, widget.name),
            widget.management.archive(widget.templateId),
          ];
          return [
            for (var i = 0; i < _menu.length; i++)
              PopupMenuItem(
                value: _menu[i],
                child: Text(const ['Rename', 'Duplicate', 'Archive'][i]),
              ),
          ];
        },
      );
}
