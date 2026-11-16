import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/history/presentation/session_history_detail_screen.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/presentation/session_notes.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  testWidgets('completed workout shows notes recorded during the session', (
    tester,
  ) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final sessions = SessionRepository(db);
    late String id;
    await tester.runAsync(() async {
      final template = await TemplateRepository(
        db,
      ).createTemplate(name: 'Push A');
      id = await sessions.startFromTemplate(template);
      await sessions.setSessionNotes(id, 'Felt strong today\nKept rest short');
      await sessions.completeSession(id);
    });
    addTearDown(() => tester.runAsync(db.close));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: SessionHistoryDetailScreen(sessionId: id)),
      ),
    );
    await drain(tester);

    expect(find.text('Felt strong today\nKept rest short'), findsOneWidget);
    expect(find.byTooltip('Edit session notes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets('edits completed workout notes and reopens them at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      final sessions = SessionRepository(db);
      final templates = TemplateRepository(db);
      late String id;
      late String template;
      late WorkoutSession completed;
      await tester.runAsync(() async {
        template = await templates.createTemplate(name: 'Pull A');
        await templates.addExercise(
          template,
          TemplateExerciseDraft(displayName: 'Row', orderLabel: '1'),
        );
        id = await sessions.startFromTemplate(template);
        final set = (await sessions.readGrid(id)).single.sets.first;
        await sessions.saveSet(set.id, weight: 70, reps: 10);
        await sessions.completeSession(id);
        completed = (await sessions.watchSession(id).first)!;
      });

      Future<void> show() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: MaterialApp(home: SessionHistoryDetailScreen(sessionId: id)),
          ),
        );
        await drain(tester);
      }

      await show();
      await tester.tap(find.byTooltip('Edit session notes'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        '  Good energy\nNext time: more rest  ',
      );
      await tester.tap(find.text('Save'));
      await drain(tester);
      expect(find.text('Good energy\nNext time: more rest'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await show();
      await tester.tap(find.byTooltip('Edit session notes'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Good energy\nNext time: more rest',
      );
      await tester.enterText(find.byType(TextField), 'Unsaved');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Good energy\nNext time: more rest'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit session notes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' \n ');
      await tester.tap(find.text('Save'));
      await drain(tester);
      expect(find.byType(ExpansionTile), findsNothing);
      await tester.runAsync(() async {
        final saved = (await sessions.watchSession(id).first)!;
        expect(saved.generalNotes, isNull);
        expect(saved.status, completed.status);
        expect(saved.completedAt, completed.completedAt);
        expect((await templates.watchTemplate(template).first)!.notes, isNull);
        final set = (await sessions.readGrid(id)).single.sets.first;
        expect(set.weight, 70);
        expect(set.reps, 10);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('obsolete notes dialog cannot save after a profile round trip', (
    tester,
  ) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final sessions = SessionRepository(db);
    late String id;
    await tester.runAsync(() async {
      final template = await TemplateRepository(
        db,
      ).createTemplate(name: 'Push A');
      id = await sessions.startFromTemplate(template);
      await sessions.setSessionNotes(id, 'Original');
      await sessions.completeSession(id);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: SessionHistoryDetailScreen(sessionId: id)),
      ),
    );
    await drain(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SessionHistoryDetailScreen)),
    );
    await tester.tap(find.byTooltip('Edit session notes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Stale draft');
    container.read(currentProfileProvider.notifier).set('other');
    container.read(currentProfileProvider.notifier).set(localProfileName);
    await tester.tap(find.text('Save'));
    await drain(tester);
    await tester.runAsync(() async {
      expect((await sessions.watchSession(id).first)!.generalNotes, 'Original');
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  group('session snapshot states', () {
    Future<void> seedCompletedSession(
      QuadrilleDatabase db, {
      required String name,
      required String notes,
      required DateTime startedAt,
      required String exerciseName,
    }) async {
      await db
          .into(db.workoutSessions)
          .insert(
            WorkoutSessionsCompanion.insert(
              id: 'session',
              name: name,
              generalNotes: Value(notes),
              status: const Value(SessionStatus.completed),
              startedAt: startedAt,
              completedAt: Value(startedAt),
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
              weight: const Value(135),
              reps: const Value(8),
              status: const Value(SetStatus.completed),
              completedAt: Value(startedAt),
              createdAt: startedAt,
              updatedAt: startedAt,
            ),
          );
    }

    for (final fail in [false, true]) {
      testWidgets(
        fail
            ? 'falls back to default title and omits metadata on reload error'
            : 'falls back to default title and omits metadata while reloading',
        (tester) async {
          driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
          final a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
          final b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
          final aRepo = _ControllableSessionRepository(a);
          final bRepo = _ControllableSessionRepository(
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
                (ref) => identical(ref.watch(databaseProvider), b)
                    ? bRepo
                    : aRepo,
              ),
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
            await seedCompletedSession(
              a,
              name: 'Push A',
              notes: 'Profile A notes',
              startedAt: DateTime(2026, 1, 5, 12),
              exerciseName: 'Bench Press',
            );
            await seedCompletedSession(
              b,
              name: 'Pull B',
              notes: 'Profile B notes',
              startedAt: DateTime(2026, 1, 6, 15, 30),
              exerciseName: 'Barbell Row',
            );
          });

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(
                home: SessionHistoryDetailScreen(sessionId: 'session'),
              ),
            ),
          );
          await drain(tester);

          expect(find.text('Push A'), findsOneWidget);
          expect(find.text('Session'), findsNothing);
          expect(find.text('Mon, Jan 5 · 12:00 PM  ·  1 sets'), findsOneWidget);
          expect(find.byType(SessionNotesCard), findsOneWidget);
          expect(find.text('Profile A notes'), findsOneWidget);
          expect(find.text('Bench Press'), findsOneWidget);

          container.read(currentProfileProvider.notifier).set('b');
          await drain(tester);

          expect(container.read(sessionProvider('session')).isLoading, isTrue);
          expect(find.text('Barbell Row'), findsOneWidget);
          expect(find.text('Session'), findsOneWidget);
          expect(find.text('Push A'), findsNothing);
          expect(find.textContaining('sets'), findsNothing);
          expect(find.byType(SessionNotesCard), findsNothing);
          expect(find.text('Profile A notes'), findsNothing);

          if (fail) {
            bRepo.firstEmission.completeError(StateError('Read failure'));
            await drain(tester);
            expect(container.read(sessionProvider('session')).hasError, isTrue);
            expect(find.text('Session'), findsOneWidget);
            expect(find.text('Push A'), findsNothing);
            expect(find.textContaining('sets'), findsNothing);
            expect(find.byType(SessionNotesCard), findsNothing);
            expect(find.text('Profile A notes'), findsNothing);
          } else {
            bRepo.firstEmission.complete();
            await drain(tester);
            expect(find.text('Pull B'), findsOneWidget);
            expect(find.text('Session'), findsNothing);
            expect(
              find.text('Tue, Jan 6 · 3:30 PM  ·  1 sets'),
              findsOneWidget,
            );
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
        final repo = _ControllableSessionRepository(db);
        final container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionRepositoryProvider.overrideWithValue(repo),
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
          () => seedCompletedSession(
            db,
            name: 'Push A',
            notes: 'Loaded notes',
            startedAt: DateTime(2026, 1, 5, 12),
            exerciseName: 'Bench Press',
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: SessionHistoryDetailScreen(sessionId: 'session'),
            ),
          ),
        );
        await drain(tester);

        expect(find.text('Push A'), findsOneWidget);
        expect(find.text('Mon, Jan 5 · 12:00 PM  ·  1 sets'), findsOneWidget);
        expect(find.byType(SessionNotesCard), findsOneWidget);
        expect(find.text('Loaded notes'), findsOneWidget);

        repo.errors.add(StateError('Stream read failed'));
        await drain(tester);

        expect(container.read(sessionProvider('session')).hasError, isTrue);
        expect(find.text('Bench Press'), findsOneWidget);
        expect(find.text('Session'), findsOneWidget);
        expect(find.text('Push A'), findsNothing);
        expect(find.textContaining('sets'), findsNothing);
        expect(find.byType(SessionNotesCard), findsNothing);
        expect(find.text('Loaded notes'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

class _ControllableSessionRepository extends SessionRepository {
  _ControllableSessionRepository(super.db, {this.holdFirstEmission = false});

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
        upstream = super.watchSession(id).listen(
          controller.add,
          onError: controller.addError,
        );
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

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
