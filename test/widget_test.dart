import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/today/presentation/today_screen.dart';

void main() {
  // Smoke test of the Today screen against a real in-memory database, proving
  // the DB opens/seeds and the end-to-end read works. We pump TodayScreen
  // directly (not the whole router shell) and use bounded pumps rather than
  // pumpAndSettle, since the shell eagerly mounts other tabs' live Drift
  // streams whose coalescing timers never let pumpAndSettle settle.
  testWidgets('Today screen reports the database ready', (tester) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: TodayScreen()),
      ),
    );
    // Build, then let the settings FutureProvider resolve.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Quadrille'), findsOneWidget);
    expect(find.textContaining('Database ready'), findsOneWidget);

    // Unmount to dispose the provider scope before teardown.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
