import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';
import 'package:quadrille/features/exercises/presentation/exercise_detail_screen.dart';

import 'history_fixture.dart';

void main() {
  late QuadrilleDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    await HistoryFixture(db).workout('workout', status: SessionStatus.active);
    await db
        .into(db.exercises)
        .insert(
          ExercisesCompanion.insert(
            id: 'catalog-bench',
            name: 'Bench Press',
            createdAt: HistoryFixture.date,
            updatedAt: HistoryFixture.date,
          ),
        );
    container.listen(exerciseByIdProvider('catalog-bench'), (_, _) {});
    container.listen(exerciseHistoryProvider('Bench Press'), (_, _) {});
    await container.read(exerciseByIdProvider('catalog-bench').future);
    await container.read(exerciseHistoryProvider('Bench Press').future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  testWidgets(
    'an open exercise detail shows a completed workout and its records',
    (tester) async {
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: ExerciseDetailScreen(exerciseId: 'catalog-bench'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('No logged sets yet.'), findsOneWidget);
        expect(find.text('100 × 10'), findsNothing);

        await tester.runAsync(() async {
          await db
              .update(db.workoutSessions)
              .write(
                const WorkoutSessionsCompanion(
                  status: Value(SessionStatus.completed),
                ),
              );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();

        expect(find.textContaining('No logged sets yet.'), findsNothing);
        expect(find.text('100 × 10'), findsOneWidget);
        expect(find.text('100 lb'), findsOneWidget);
        expect(find.text('133.3 lb'), findsOneWidget);
        expect(find.text('1'), findsOneWidget);

        await tester.runAsync(() async {
          await db
              .update(db.workoutSessions)
              .write(
                WorkoutSessionsCompanion(deletedAt: Value(HistoryFixture.date)),
              );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
        expect(find.textContaining('No logged sets yet.'), findsOneWidget);
        expect(find.text('100 × 10'), findsNothing);
        expect(find.text('0'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
