import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/app/app.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';

void main() {
  testWidgets('app boots, shows Today, and reports the database ready',
      (tester) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const QuadrilleApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Quadrille'), findsOneWidget);
    expect(find.textContaining('Database ready'), findsOneWidget);

    // All five shell destinations are present in the navigation.
    for (final label in [
      'Today',
      'Templates',
      'History',
      'Exercises',
      'Settings',
    ]) {
      expect(find.text(label), findsWidgets);
    }
  });
}
