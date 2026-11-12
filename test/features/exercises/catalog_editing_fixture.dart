import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';
import 'package:quadrille/features/exercises/presentation/exercise_detail_screen.dart';
import 'package:quadrille/features/exercises/presentation/exercises_screen.dart';

import '../session/session_starting_fixture.dart' show drain;

class CatalogWait {
  final entered = Completer<void>();
  final completion = Completer<void>();
}

/// Gate the actual submission while retaining the production SQLite adapter.
class CatalogRepository extends ExerciseRepository {
  CatalogRepository(super.db);

  CatalogWait? waiting;
  bool fail = false;
  int submissions = 0;
  Completer<Exercise?>? reading;

  Future<void> _wait() async {
    submissions++;
    final gate = waiting;
    if (gate != null) {
      if (!gate.entered.isCompleted) gate.entered.complete();
      await gate.completion.future;
    }
    if (fail) throw StateError('Disk full');
  }

  @override
  Future<Exercise?> getById(String id) => reading?.future ?? super.getById(id);

  @override
  Future<String> create({
    required String name,
    ExerciseCategory category = ExerciseCategory.other,
    int defaultRestSeconds = 120,
    LoadKind loadKind = LoadKind.externalWeight,
    bool isUnilateral = false,
    String? notes,
  }) async {
    await _wait();
    return super.create(
      name: name,
      category: category,
      defaultRestSeconds: defaultRestSeconds,
      loadKind: loadKind,
      isUnilateral: isUnilateral,
      notes: notes,
    );
  }

  @override
  Future<void> update(
    String id, {
    String? name,
    ExerciseCategory? category,
    int? defaultRestSeconds,
    LoadKind? loadKind,
    bool? isUnilateral,
    String? notes,
  }) async {
    await _wait();
    await super.update(
      id,
      name: name,
      category: category,
      defaultRestSeconds: defaultRestSeconds,
      loadKind: loadKind,
      isUnilateral: isUnilateral,
      notes: notes,
    );
  }
}

class CatalogEditingFixture {
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  late QuadrilleDatabase current;
  late CatalogRepository aRepository;
  late CatalogRepository bRepository;
  late ProviderContainer container;
  bool disposed = false;

  Future<void> open() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    for (final db in [a, b]) {
      await db
          .into(db.exercises)
          .insert(
            ExercisesCompanion.insert(
              id: 'e1',
              name: identical(db, a) ? 'A exercise' : 'B exercise',
              notes: const Value('Original notes'),
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
          );
    }
    aRepository = CatalogRepository(a);
    bRepository = CatalogRepository(b);
    current = a;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          ref.watch(currentProfileProvider);
          return current;
        }),
        exerciseRepositoryProvider.overrideWith((ref) {
          final db = ref.watch(databaseProvider);
          return identical(db, a) ? aRepository : bRepository;
        }),
      ],
    );
  }

  void switchToB() {
    current = b;
    container.read(currentProfileProvider.notifier).set('b');
  }

  Future<void> close() async {
    if (!disposed) container.dispose();
    await a.close();
    await b.close();
  }
}

Future<void> showCatalog(
  WidgetTester tester,
  CatalogEditingFixture fixture, {
  required bool editing,
  GlobalKey<NavigatorState>? navigator,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(
        navigatorKey: navigator,
        home: editing
            ? const ExerciseDetailScreen(exerciseId: 'e1')
            : const ExercisesScreen(),
      ),
    ),
  );
  await drain(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> openCatalogEditor(WidgetTester tester, bool editing) async {
  await tester.tap(
    editing ? find.byTooltip('Edit') : find.byType(FloatingActionButton),
  );
  await tester.pumpAndSettle();
}

Finder catalogSave(bool editing) =>
    find.widgetWithText(FilledButton, editing ? 'Save' : 'Add exercise');

Future<void> saveCatalogEditor(WidgetTester tester, bool editing) async {
  await tester.ensureVisible(catalogSave(editing));
  await tester.tap(catalogSave(editing));
}
