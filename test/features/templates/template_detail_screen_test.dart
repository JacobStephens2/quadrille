import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/templates/presentation/template_detail_screen.dart';
import 'package:quadrille/features/templates/template_providers.dart';

/// Built by hand (no Drift database) so the widget test holds no SQLite
/// isolate/stream — opening or closing one inside flutter_test races the test
/// harness channel. The data behaviour is covered by the repository tests.
WorkoutTemplate _template() => WorkoutTemplate(
      id: 't1',
      name: 'Day 1 Push A',
      sortOrder: 0,
      archived: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

TemplateExercise _row({
  required String id,
  required String name,
  required String orderLabel,
  required int sortIndex,
  String? supersetGroup,
  int targetSets = 3,
  int? repMin,
  int? repMax,
  int restSeconds = 120,
  String? notes,
}) =>
    TemplateExercise(
      id: id,
      templateId: 't1',
      displayName: name,
      orderLabel: orderLabel,
      sortIndex: sortIndex,
      supersetGroup: supersetGroup,
      targetSets: targetSets,
      repMin: repMin,
      repMax: repMax,
      restSeconds: restSeconds,
      notes: notes,
      isUnilateral: false,
      loadKind: LoadKind.externalWeight,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  testWidgets('renders template rows in sheet order with their spec',
      (tester) async {
    final rows = [
      _row(
        id: 'r1',
        name: 'Overhead Press',
        orderLabel: '1',
        sortIndex: 100,
        targetSets: 4,
        repMin: 6,
        repMax: 8,
        restSeconds: 180,
      ),
      _row(
        id: 'r2',
        name: 'Cable Fly',
        orderLabel: '2A',
        sortIndex: 201,
        supersetGroup: '2',
        repMin: 12,
        repMax: 20,
        notes: 'bench 8',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          templateProvider.overrideWith((ref, id) => Stream.value(_template())),
          templateExercisesProvider
              .overrideWith((ref, id) => Stream.value(rows)),
        ],
        child: const MaterialApp(
          home: TemplateDetailScreen(templateId: 't1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Day 1 Push A'), findsOneWidget);
    expect(find.text('Overhead Press'), findsOneWidget);
    expect(find.text('Cable Fly'), findsOneWidget);
    expect(find.textContaining("4 sets · 6-8 · rest 3'"), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2A'), findsOneWidget);
    expect(find.textContaining('bench 8'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
