import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/core/retained_opening.dart';

enum FakeState { idle, pending, accepted, refused, failed, superseded }

class FakeGate {
  final entered = Completer<void>();
  final completion = Completer<void>();
  bool fail = false;
  bool result = true;
}

/// A fake captured destination with gated persistence, mirroring the
/// controlled repositories in the feature fixtures.
class FakeDestination {
  String value = 'Original';
  int attempts = 0;
  FakeGate? waiting;

  Future<bool> persist(String write) async {
    attempts++;
    final gate = waiting;
    if (gate != null) {
      gate.entered.complete();
      await gate.completion.future;
      if (gate.fail) throw StateError('Controlled persistence failure');
      if (!gate.result) return false;
    }
    value = write;
    return true;
  }
}

final fakeDestinationProvider = Provider<FakeDestination>(
  (ref) => FakeDestination(),
);

/// The smallest feature-shaped adapter over the Retained opening module:
/// an owner factory, a completed-result mapping, and a retire hook counter.
class FakeEditing {
  FakeEditing._(this._owner, this._destination);

  final RetainedOpeningOwner _owner;
  final FakeDestination _destination;

  FakeOpening open() => FakeOpening._(_owner, _destination);
}

final fakeEditingProvider = Provider<FakeEditing>((ref) {
  final generation = ref.watch(localProfileGenerationProvider);
  final destination = ref.watch(fakeDestinationProvider);
  return FakeEditing._(
    RetainedOpeningOwner(
      ref,
      generation,
      destinations: [
        RetainedDestination(
          destination,
          () => ref.read(fakeDestinationProvider),
        ),
      ],
    ),
    destination,
  );
});

class FakeOpening extends RetainedOpening<FakeState> {
  FakeOpening._(super.owner, this._destination)
    : super(
        idle: FakeState.idle,
        pending: FakeState.pending,
        failed: FakeState.failed,
        superseded: FakeState.superseded,
      );

  final FakeDestination _destination;
  int retireHookCalls = 0;

  @override
  void onRetired() => retireHookCalls++;

  Future<FakeState> perform(String write, {Object? sharingKey}) =>
      submitPersistence(
        () => _destination.persist(write),
        mapCompleted: (accepted) =>
            accepted ? FakeState.accepted : FakeState.refused,
        sharingKey: sharingKey,
      );

  Future<FakeState> performBlank() =>
      Future<FakeState>.value(failWithoutPersisting());

  Future<FakeState> performThrowingMap(String write) => submitPersistence(
    () => _destination.persist(write),
    mapCompleted: (_) => throw StateError('Controlled mapping failure'),
  );

  Future<FakeState> performText({Object? sharingKey}) =>
      submitPersistence<String>(
        () async => 'text-result',
        mapCompleted: (_) => FakeState.accepted,
        sharingKey: sharingKey,
      );
}

class RetainedFixture {
  RetainedFixture() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  }

  late final a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  late final b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  late final aDestination = FakeDestination();
  late final bDestination = FakeDestination();
  late QuadrilleDatabase current = a;
  late ProviderContainer container;
  bool disposed = false;
  FakeDestination? replacement;

  void open() => createOwner();

  void createOwner() {
    disposed = false;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) {
          ref.watch(currentProfileProvider);
          return current;
        }),
        fakeDestinationProvider.overrideWith((ref) {
          final db = ref.watch(databaseProvider);
          return replacement ??
              (identical(db, a) ? aDestination : bDestination);
        }),
      ],
    );
  }

  void switchToB() {
    current = b;
    container.read(currentProfileProvider.notifier).set('b');
  }

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
