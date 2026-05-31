import 'package:flutter/material.dart';

/// Quadrille's visual identity leans into its namesake: graph paper. A
/// blue-gray seed, thin square-edged dividers, and a subtle grid motif behind
/// hero surfaces. Square-ish corners echo the grid cells.
abstract final class QuadrilleTheme {
  /// Blue-gray graph-paper accent.
  static const Color seed = Color(0xFF3F5C78);

  /// The faint grid-line color used by [GridPaperBackground].
  static Color gridLine(Brightness b) => b == Brightness.dark
      ? const Color(0x14FFFFFF)
      : const Color(0x11304254);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }
}

/// A subtle graph-paper grid painted behind a surface — the literal "quadrille"
/// motif. Cheap [CustomPaint]; cells default to 24 logical px.
class GridPaperBackground extends StatelessWidget {
  const GridPaperBackground({
    super.key,
    required this.child,
    this.cell = 24,
  });

  final Widget child;
  final double cell;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return CustomPaint(
      painter: _GridPainter(
        color: QuadrilleTheme.gridLine(brightness),
        cell: cell,
      ),
      child: child,
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color, required this.cell});

  final Color color;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.color != color || old.cell != cell;
}
