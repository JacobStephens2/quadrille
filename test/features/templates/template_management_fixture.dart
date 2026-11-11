import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/template_providers.dart';

class ManagementGate {
  final entered = Completer<void>();
  final completion = Completer<void>();
}

/// Gate the existing repository submission, retaining real SQLite persistence.
class ManagementRepository extends TemplateRepository {
  ManagementRepository(super.db) : _database = db;

  final QuadrilleDatabase _database;

  ManagementGate? gate;
  bool fail = false;
  int submissions = 0;

  Future<void> _accept() async {
    submissions++;
    final wait = gate;
    if (wait != null) {
      if (!wait.entered.isCompleted) wait.entered.complete();
      await wait.completion.future;
    }
    if (fail) throw StateError('Disk full');
  }

  @override
  Future<String> createTemplate({
    required String name,
    String? dayLabel,
    int sortOrder = 0,
    String? notes,
  }) async {
    await _accept();
    return super.createTemplate(
      name: name,
      dayLabel: dayLabel,
      sortOrder: sortOrder,
      notes: notes,
    );
  }

  @override
  Future<void> updateTemplate(
    String id, {
    String? name,
    String? dayLabel,
    int? sortOrder,
    String? notes,
  }) async {
    await _accept();
    await super.updateTemplate(
      id,
      name: name,
      dayLabel: dayLabel,
      sortOrder: sortOrder,
      notes: notes,
    );
  }

  @override
  Future<String> duplicateTemplate(String id, {required String newName}) async {
    await _accept();
    // The copy transaction calls createTemplate internally; gate only its entry.
    return TemplateRepository(
      _database,
    ).duplicateTemplate(id, newName: newName);
  }

  @override
  Future<void> archiveTemplate(String id) async {
    await _accept();
    await super.archiveTemplate(id);
  }
}

class ManagementFixture {
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  late QuadrilleDatabase current;
  late ManagementRepository aRepository;
  late ManagementRepository bRepository;
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
              dayLabel: const Value('Monday'),
              sortOrder: const Value(4),
              notes: const Value('Warm up'),
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
    }
    current = a;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          ref.watch(currentProfileProvider);
          return current;
        }),
        templateRepositoryProvider.overrideWith((ref) {
          final db = ref.watch(databaseProvider);
          if (identical(db, a)) return aRepository = ManagementRepository(a);
          return bRepository = ManagementRepository(b);
        }),
      ],
    );
    aRepository =
        container.read(templateRepositoryProvider) as ManagementRepository;
    bRepository = ManagementRepository(b);
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
