import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/presentation/session_notes.dart';
import 'package:quadrille/features/session/session_providers.dart';

import 'session_starting_fixture.dart' show drain;

/// Test boundary over [SessionRepository] that can hold reload emissions and
/// inject stream errors on [watchSession] while grids continue reading from SQLite.
class ControllableSessionRepository extends SessionRepository {
  ControllableSessionRepository(super.db, {this.holdFirstEmission = false});

  final bool holdFirstEmission;
  final firstEmission = Completer<void>();
  final errors = StreamController<Object>.broadcast();

  @override
  Stream<WorkoutSession?> watchSession(String id) {
    late final StreamController<WorkoutSession?> controller;
    StreamSubscription<WorkoutSession?>? upstream;
    StreamSubscription<Object>? errorSub;

    controller = StreamController<WorkoutSession?>(
      onListen: () async {
        if (holdFirstEmission) {
          try {
            await firstEmission.future;
          } catch (error, stack) {
            if (!controller.isClosed) controller.addError(error, stack);
            return;
          }
        }
        if (controller.isClosed) return;
        upstream = super
            .watchSession(id)
            .listen(controller.add, onError: controller.addError);
        errorSub = errors.stream.listen(controller.addError);
      },
      onCancel: () async {
        await upstream?.cancel();
        await errorSub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> close() => errors.close();
}

Future<void> _seedSession(
  QuadrilleDatabase db, {
  required SessionStatus status,
  required String name,
  required String notes,
  required DateTime startedAt,
  required String exerciseName,
}) async {
  final completed = status == SessionStatus.completed;
  await db
      .into(db.workoutSessions)
      .insert(
        WorkoutSessionsCompanion.insert(
          id: 'session',
          name: name,
          generalNotes: Value(notes),
          status: Value(status),
          startedAt: startedAt,
          completedAt: Value(completed ? startedAt : null),
          createdAt: startedAt,
          updatedAt: startedAt,
        ),
      );
  await db
      .into(db.sessionExercises)
      .insert(
        SessionExercisesCompanion.insert(
          id: 'exercise',
          sessionId: 'session',
          displayName: exerciseName,
          orderLabel: '1',
          sortIndex: 0,
          createdAt: startedAt,
          updatedAt: startedAt,
        ),
      );
  await db
      .into(db.setEntries)
      .insert(
        SetEntriesCompanion.insert(
          id: 'set-1',
          sessionExerciseId: 'exercise',
          setNumber: 1,
          weight: Value(completed ? 135 : null),
          reps: Value(completed ? 8 : null),
          status: Value(completed ? SetStatus.completed : SetStatus.pending),
          completedAt: Value(completed ? startedAt : null),
          createdAt: startedAt,
          updatedAt: startedAt,
        ),
      );
}

void _expectOmittedMetadata({
  required String fallbackTitle,
  required String omittedTitle,
  required String omittedNotes,
  required String? omittedTimestamp,
}) {
  expect(find.text(fallbackTitle), findsOneWidget);
  expect(find.text(omittedTitle), findsNothing);
  expect(find.byType(SessionNotesCard), findsNothing);
  expect(find.text(omittedNotes), findsNothing);
  if (omittedTimestamp != null) {
    expect(find.text(omittedTimestamp), findsNothing);
    expect(find.textContaining('sets'), findsNothing);
  }
}

/// Registers reload, failed-reload, and stream-error snapshot tests for a
/// screen watching `sessionProvider('session')`.
void registerSessionSnapshotStateTests({
  required SessionStatus status,
  required String fallbackTitle,
  required Widget screen,
  List<Override> extraOverrides = const [],
  String? loadedTimestamp,
  String? reloadedTimestamp,
}) {
  group('session snapshot states', () {
    for (final fail in [false, true]) {
      testWidgets(
        fail
            ? 'falls back to default title and omits metadata on reload error'
            : 'falls back to default title and omits metadata while reloading',
        (tester) async {
          driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
          final a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
          final b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
          final aRepo = ControllableSessionRepository(a);
          final bRepo = ControllableSessionRepository(
            b,
            holdFirstEmission: true,
          );
          final container = ProviderContainer(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith(
                (ref) => ref.watch(currentProfileProvider) == 'b' ? b : a,
              ),
              sessionRepositoryProvider.overrideWith(
                (ref) =>
                    identical(ref.watch(databaseProvider), b) ? bRepo : aRepo,
              ),
              ...extraOverrides,
            ],
          );
          addTearDown(() async {
            if (!bRepo.firstEmission.isCompleted) {
              bRepo.firstEmission.complete();
            }
            await aRepo.close();
            await bRepo.close();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            container.dispose();
            await tester.runAsync(() async {
              await a.close();
              await b.close();
            });
          });
          await tester.runAsync(() async {
            await _seedSession(
              a,
              status: status,
              name: 'Push A',
              notes: 'Profile A notes',
              startedAt: DateTime(2026, 1, 5, 12),
              exerciseName: 'Bench Press',
            );
            await _seedSession(
              b,
              status: status,
              name: 'Pull B',
              notes: 'Profile B notes',
              startedAt: DateTime(2026, 1, 6, 15, 30),
              exerciseName: 'Barbell Row',
            );
          });

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(home: screen),
            ),
          );
          await drain(tester);

          expect(find.text('Push A'), findsOneWidget);
          expect(find.text(fallbackTitle), findsNothing);
          if (loadedTimestamp != null) {
            expect(find.text(loadedTimestamp), findsOneWidget);
          }
          expect(find.byType(SessionNotesCard), findsOneWidget);
          expect(find.text('Profile A notes'), findsOneWidget);
          expect(find.text('Bench Press'), findsOneWidget);

          container.read(currentProfileProvider.notifier).set('b');
          await drain(tester);

          expect(container.read(sessionProvider('session')).isLoading, isTrue);
          expect(find.text('Barbell Row'), findsOneWidget);
          _expectOmittedMetadata(
            fallbackTitle: fallbackTitle,
            omittedTitle: 'Push A',
            omittedNotes: 'Profile A notes',
            omittedTimestamp: loadedTimestamp,
          );

          if (fail) {
            bRepo.firstEmission.completeError(StateError('Read failure'));
            await drain(tester);
            expect(container.read(sessionProvider('session')).hasError, isTrue);
            _expectOmittedMetadata(
              fallbackTitle: fallbackTitle,
              omittedTitle: 'Push A',
              omittedNotes: 'Profile A notes',
              omittedTimestamp: loadedTimestamp,
            );
          } else {
            bRepo.firstEmission.complete();
            await drain(tester);
            expect(find.text('Pull B'), findsOneWidget);
            expect(find.text(fallbackTitle), findsNothing);
            if (reloadedTimestamp != null) {
              expect(find.text(reloadedTimestamp), findsOneWidget);
            }
            expect(find.byType(SessionNotesCard), findsOneWidget);
            expect(find.text('Profile B notes'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'falls back to default title and omits metadata on stream error after load',
      (tester) async {
        final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
        final repo = ControllableSessionRepository(db);
        final container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionRepositoryProvider.overrideWithValue(repo),
            ...extraOverrides,
          ],
        );
        addTearDown(() async {
          await repo.close();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          container.dispose();
          await tester.runAsync(db.close);
        });
        await tester.runAsync(
          () => _seedSession(
            db,
            status: status,
            name: 'Push A',
            notes: 'Loaded notes',
            startedAt: DateTime(2026, 1, 5, 12),
            exerciseName: 'Bench Press',
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: screen),
          ),
        );
        await drain(tester);

        expect(find.text('Push A'), findsOneWidget);
        if (loadedTimestamp != null) {
          expect(find.text(loadedTimestamp), findsOneWidget);
        }
        expect(find.byType(SessionNotesCard), findsOneWidget);
        expect(find.text('Loaded notes'), findsOneWidget);

        repo.errors.add(StateError('Stream read failed'));
        await drain(tester);

        expect(container.read(sessionProvider('session')).hasError, isTrue);
        expect(find.text('Bench Press'), findsOneWidget);
        _expectOmittedMetadata(
          fallbackTitle: fallbackTitle,
          omittedTitle: 'Push A',
          omittedNotes: 'Loaded notes',
          omittedTimestamp: loadedTimestamp,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
