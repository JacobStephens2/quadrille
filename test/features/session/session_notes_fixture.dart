import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/session_providers.dart';

import '../exercises/history_fixture.dart';

class NotesWrite {
  final entered = Completer<void>();
  final completion = Completer<void>();
  bool fail = false;
}

/// Controlled persistence adapter; successful writes use the real repository.
class NotesRepository extends SessionRepository {
  NotesRepository(super.db);

  NotesWrite? waiting;
  int submissions = 0;

  @override
  Future<void> setSessionNotes(String sessionId, String? notes) async {
    submissions++;
    final gate = waiting;
    if (gate != null) {
      gate.entered.complete();
      await gate.completion.future;
      if (gate.fail) throw StateError('Controlled notes failure');
    }
    await super.setSessionNotes(sessionId, notes);
  }
}

class NotesFixture {
  NotesFixture({this.active = false}) {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  }

  final bool active;
  late final a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  late final b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  late final aRepository = NotesRepository(a);
  late final bRepository = NotesRepository(b);
  late QuadrilleDatabase current = a;
  late ProviderContainer container;
  bool disposed = false;
  NotesRepository? replacement;

  Future<void> open() async {
    for (final db in [a, b]) {
      await HistoryFixture(db).workout(
        'session',
        status: active ? SessionStatus.active : SessionStatus.completed,
      );
      await SessionRepository(db).setSessionNotes('session', 'Original');
    }
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

  Future<String?> notes(NotesRepository repository) async =>
      (await repository.watchSession('session').first)!.generalNotes;

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
