import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/session_providers.dart';

import '../exercises/history_fixture.dart';

class DeletionWrite {
  final entered = Completer<void>();
  final completion = Completer<void>();
  bool fail = false;
  bool unavailable = false;
}

/// Controls admission timing; successful deletion uses the real repository.
class DeletionRepository extends SessionRepository {
  DeletionRepository(super.db);

  DeletionWrite? waiting;
  int submissions = 0;

  @override
  Future<bool> deleteCompletedSession(String sessionId) async {
    submissions++;
    final gate = waiting;
    if (gate != null) {
      gate.entered.complete();
      await gate.completion.future;
      if (gate.fail) throw StateError('Controlled deletion failure');
      if (gate.unavailable) return false;
    }
    return super.deleteCompletedSession(sessionId);
  }
}

class DeletionFixture {
  DeletionFixture() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  }

  late final a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  late final b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  late final aRepository = DeletionRepository(a);
  late final bRepository = DeletionRepository(b);
  late QuadrilleDatabase current = a;
  late ProviderContainer container;
  bool disposed = false;
  DeletionRepository? replacement;

  Future<void> open() async {
    for (final db in [a, b]) {
      await HistoryFixture(db).workout('session');
    }
    createOwner();
  }

  void createOwner() {
    disposed = false;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          ref.watch(currentProfileProvider);
          return current;
        }),
        sessionRepositoryProvider.overrideWith((ref) {
          final db = ref.watch(databaseProvider);
          return replacement ?? (identical(db, a) ? aRepository : bRepository);
        }),
      ],
    );
  }

  void switchToB() {
    current = b;
    container.read(currentProfileProvider.notifier).set('b');
  }

  Future<bool> exists(DeletionRepository repository) async =>
      (await repository.watchHistory().first).any((s) => s.id == 'session');

  void disposeOwner() {
    container.dispose();
    disposed = true;
  }

  Future<void> close() async {
    if (!disposed) container.dispose();
    await a.close();
    await b.close();
  }
}
