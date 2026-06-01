import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/templates/template_providers.dart';
import 'package:quadrille/features/today/presentation/today_screen.dart';

void main() {
  // Driven from Stream.value overrides (no Drift database) — opening one inside
  // flutter_test races the harness channel, and live .watch() streams never
  // let pumpAndSettle settle. Data behaviour is covered by repository tests.
  testWidgets('Today shows the start view when there is no active session',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionProvider.overrideWith((ref) => Stream.value(null)),
          templatesProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: const MaterialApp(home: TodayScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Quadrille'), findsOneWidget);
    expect(find.textContaining('Start by building a template'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Today resumes an in-progress session', (tester) async {
    final session = WorkoutSession(
      id: 's1',
      name: 'Day 1 Push A',
      status: SessionStatus.active,
      startedAt: DateTime(2026),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionProvider.overrideWith((ref) => Stream.value(session)),
          // Resume card reads the grid; loading is fine (no progress line).
          sessionGridProvider.overrideWith((ref, arg) => const AsyncValue.loading()),
        ],
        child: const MaterialApp(home: TodayScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Day 1 Push A'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
