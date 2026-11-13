import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Captured invoking screen and optional owned modal for one interaction.
///
/// Visibility is evaluated at completion, so temporary covers can recover.
/// Local profile ownership and per-attempt result silence belong to callers.
class PresentationOpening {
  PresentationOpening._(
    this._sourceContext,
    this._sourceRoutes,
    this._router,
    this._location, {
    this._modalContext,
    this._modalRoute,
  });

  /// Capture before pushing any menu, dialog, or sheet.
  factory PresentationOpening.capture(BuildContext context) {
    if (!context.mounted) {
      return PresentationOpening._(context, const [], null, null);
    }
    final router = GoRouter.maybeOf(context);
    final routes = <ModalRoute<dynamic>>[];
    BuildContext? scope = context;
    while (scope != null) {
      final route = ModalRoute.of(scope);
      if (route != null) routes.add(route);
      // The Navigator's context is in its enclosing route's scope.
      scope = scope.findAncestorStateOfType<NavigatorState>()?.context;
    }
    return PresentationOpening._(
      context,
      routes,
      router,
      router?.routeInformationProvider.value.uri,
    );
  }

  final BuildContext _sourceContext;
  final List<ModalRoute<dynamic>> _sourceRoutes;
  final GoRouter? _router;
  final Uri? _location;
  final BuildContext? _modalContext;
  final ModalRoute<dynamic>? _modalRoute;

  /// Bind from this opening's own modal builder, retaining the original source.
  PresentationOpening bindModal(BuildContext context) => PresentationOpening._(
    _sourceContext,
    _sourceRoutes,
    _router,
    _location,
    modalContext: context,
    modalRoute: context.mounted ? ModalRoute.of(context) : null,
  );

  /// Whether this exact source and, when bound, owned modal may present effects.
  bool get isCurrent {
    if (!_sourceContext.mounted || _sourceRoutes.isEmpty) return false;
    final modalContext = _modalContext;
    final modal = _modalRoute;
    if (modalContext != null &&
        (!modalContext.mounted ||
            modal == null ||
            !modal.isActive ||
            !modal.isCurrent)) {
      return false;
    }
    if (!_sourceRoutes.every(
      (route) =>
          route.isActive &&
          (route.isCurrent ||
              (modal != null && identical(route.navigator, modal.navigator))),
    )) {
      return false;
    }
    return TickerMode.valuesOf(_sourceContext).enabled &&
        (_router == null ||
            _router.routeInformationProvider.value.uri == _location);
  }
}
