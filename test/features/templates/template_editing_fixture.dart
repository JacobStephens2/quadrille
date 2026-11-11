import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/templates/presentation/template_detail_screen.dart';
import 'package:quadrille/features/templates/template_providers.dart';

import '../session/session_starting_fixture.dart' show drain;

Future<void> showTemplateDetail(
  WidgetTester tester,
  TemplateEditingFixture fixture, {
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: const TemplateDetailScreen(templateId: 't1'),
      ),
    ),
  );
  await drain(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> openTemplateEditor(
  WidgetTester tester, {
  required bool editing,
}) async {
  await tester.tap(find.text(editing ? 'Bench Press' : 'Row'));
  await tester.pumpAndSettle();
}

Finder editorSave(bool editing) =>
    find.widgetWithText(FilledButton, editing ? 'Save row' : 'Add row');

Future<void> saveTemplateEditor(
  WidgetTester tester, {
  required bool editing,
}) async {
  final button = editorSave(editing);
  await tester.ensureVisible(button);
  await tester.tap(button);
}

class EditingWait {
  final entered = Completer<void>();
  final completion = Completer<void>();
}

/// Gate only the existing persistence call; all writes still use real SQLite.
class EditingRepository extends TemplateRepository {
  EditingRepository(super.db);

  EditingWait? waiting;
  bool fail = false;
  int submissions = 0;

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
  Future<String> addExercise(
    String templateId,
    TemplateExerciseDraft draft,
  ) async {
    await _wait();
    return super.addExercise(templateId, draft);
  }

  @override
  Future<void> updateExercise(
    String id,
    String templateId,
    TemplateExerciseDraft draft,
  ) async {
    await _wait();
    await super.updateExercise(id, templateId, draft);
  }

  @override
  Future<void> deleteExercise(String id) async {
    await _wait();
    await super.deleteExercise(id);
  }
}

class TemplateEditingFixture {
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  late QuadrilleDatabase current;
  late EditingRepository aRepository;
  late EditingRepository bRepository;
  late ProviderContainer container;
  bool disposed = false;

  Future<void> open() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    for (final db in [a, b]) {
      final now = DateTime(2026);
      await db
          .into(db.workoutTemplates)
          .insert(
            WorkoutTemplatesCompanion.insert(
              id: 't1',
              name: 'Push A',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.templateExercises)
          .insert(
            TemplateExercisesCompanion.insert(
              id: 'r1',
              templateId: 't1',
              displayName: 'Bench Press',
              orderLabel: '1',
              sortIndex: 100,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await ExerciseRepository(
        db,
      ).create(name: identical(db, a) ? 'A catalog' : 'B catalog');
    }
    aRepository = EditingRepository(a);
    bRepository = EditingRepository(b);
    current = a;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          ref.watch(currentProfileProvider);
          return current;
        }),
        templateRepositoryProvider.overrideWith((ref) {
          final db = ref.watch(databaseProvider);
          if (identical(db, a)) return aRepository = EditingRepository(a);
          return bRepository = EditingRepository(b);
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
