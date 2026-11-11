import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/session_providers.dart';

class StartingWait {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

/// Keeps real transactional snapshots, controlling only repository submission.
class StartingRepository extends SessionRepository {
  StartingRepository(super.db);

  StartingWait? waiting;
  bool fail = false;
  int submissions = 0;

  @override
  Future<String> startFromTemplate(String templateId) async {
    submissions++;
    await waiting?.wait();
    if (fail) throw StateError('Disk full');
    return super.startFromTemplate(templateId);
  }
}

class StartingFixture {
  static const templateId = 'push';
  final databases = <QuadrilleDatabase>[];
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  late StartingRepository aRepository;
  late StartingRepository bRepository;
  late ProviderContainer container;
  bool disposed = false;

  Future<QuadrilleDatabase> addDatabase() async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    databases.add(db);
    final now = DateTime(2026);
    await db
        .into(db.workoutTemplates)
        .insert(
          WorkoutTemplatesCompanion.insert(
            id: templateId,
            name: 'Push A',
            notes: const Value('Warm up first'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.templateExercises)
        .insert(
          TemplateExercisesCompanion.insert(
            id: 'press',
            templateId: templateId,
            displayName: 'Bench Press',
            orderLabel: '1',
            sortIndex: 100,
            targetSets: const Value(3),
            repMin: const Value(6),
            repMax: const Value(8),
            restSeconds: const Value(180),
            notes: const Value('Slow eccentric'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return db;
  }

  Future<void> open() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    a = await addDatabase();
    b = await addDatabase();
    aRepository = StartingRepository(a);
    bRepository = StartingRepository(b);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith(
          (ref) => ref.watch(currentProfileProvider) == 'b' ? b : a,
        ),
        sessionRepositoryProvider.overrideWith((ref) {
          ref.watch(databaseProvider);
          return ref.watch(currentProfileProvider) == 'b'
              ? bRepository
              : aRepository;
        }),
      ],
    );
    switchTo('a');
  }

  void switchTo(String name) =>
      container.read(currentProfileProvider.notifier).set(name);

  void disposeOwner() {
    container.dispose();
    disposed = true;
  }

  Future<void> close() async {
    if (!disposed) container.dispose();
    for (final db in databases) {
      await db.close();
    }
  }
}
