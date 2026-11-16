import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/presentation/active_session_screen.dart';
import 'package:quadrille/features/session/presentation/session_exercise_card.dart';
import 'package:quadrille/features/session/presentation/session_notes.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

class _Notifications implements NotificationService {
  String? body;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    this.body = body;
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {}
}

class _Watch implements WatchService {
  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {}

  @override
  Future<void> clear() async {}
}

class _LocalAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}

void main() {
  group('session notes', () {
    late QuadrilleDatabase db;
    late SessionRepository sessions;
    late TemplateRepository templates;
    late String templateId;
    late String sessionId;

    Future<void> startSession(
      WidgetTester tester, {
      String? notes,
      bool withExercise = true,
    }) async {
      db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      sessions = SessionRepository(db);
      templates = TemplateRepository(db);
      await tester.runAsync(() async {
        templateId = await templates.createTemplate(name: 'Push A', notes: notes);
        if (withExercise) {
          await templates.addExercise(
            templateId,
            TemplateExerciseDraft(displayName: 'Bench Press', orderLabel: '1A'),
          );
        }
        sessionId = await sessions.startFromTemplate(templateId);
      });
    }

    Future<void> showSession(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            watchServiceProvider.overrideWithValue(_Watch()),
            authControllerProvider.overrideWith(_LocalAuth.new),
          ],
          child: MaterialApp(home: ActiveSessionScreen(sessionId: sessionId)),
        ),
      );
      await tester.runAsync(() async {
        await sessions.watchGrid(sessionId).first;
      });
      await tester.pumpAndSettle();
    }

    Future<void> closeSession(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(db.close);
    }

    Future<void> saveNotes(WidgetTester tester, String? expected) async {
      await tester.tap(find.text('Save'));
      WorkoutSession? saved;
      // Drain Flutter's dialog futures and Drift's database work together.
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        saved = await tester.runAsync<WorkoutSession?>(
          () => sessions.watchSession(sessionId).first,
        );
        if (saved?.generalNotes == expected) break;
      }
      expect(saved!.generalNotes, expected);
      await tester.pumpAndSettle();
    }

    testWidgets('shows primer above the first exercise and can collapse it', (
      tester,
    ) async {
      const primer =
          '4-minute primer\nThoracic Windmills\n'
          'Supinated Band Pull-Aparts\nStanding Ribcage Circles\n'
          'Deep Squat Ankle Rocks';
      await startSession(tester, notes: primer);
      await showSession(tester);

      expect(find.text(primer), findsOneWidget);
      expect(
        tester.getBottomLeft(find.text(primer)).dy,
        lessThan(tester.getTopLeft(find.byType(SessionExerciseCard).first).dy),
      );
      await tester.tap(find.text('Session notes'));
      await tester.pumpAndSettle();
      expect(find.text(primer), findsNothing);
      await tester.tap(find.text('Session notes'));
      await tester.pumpAndSettle();
      expect(find.text(primer), findsOneWidget);
      await closeSession(tester);
    });

    testWidgets('busy reports work for a template-only exercise without changing sets or rest', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await startSession(tester);
      await showSession(tester);

      await tester.tap(find.text('Equipment busy'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Busy times'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('1 busy report'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ActiveSessionScreen)),
      );
      await tester.runAsync(() async {
        final sets = (await sessions.readGrid(sessionId)).single.sets;
        expect(sets, hasLength(3));
        expect(sets.every((s) => s.status == SetStatus.pending), isTrue);
        expect(await container.refresh(activeTimerProvider.future), isNull);
      });
      expect(tester.takeException(), isNull);
      await closeSession(tester);
    });

    testWidgets('edits persist after reopening and cancel preserves notes', (
      tester,
    ) async {
      await startSession(tester, notes: '4-minute primer');
      await showSession(tester);

      await tester.tap(find.byTooltip('Edit session notes'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '4-minute primer',
      );
      await tester.enterText(find.byType(TextField), 'Unsaved change');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('4-minute primer'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit session notes'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Primer complete\nKeep shoulders relaxed',
      );
      await saveNotes(tester, 'Primer complete\nKeep shoulders relaxed');
      await tester.runAsync(() async {
        expect(
          (await templates.watchTemplate(templateId).first)!.notes,
          '4-minute primer',
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('Primer complete\nKeep shoulders relaxed'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await showSession(tester);
      expect(find.text('Primer complete\nKeep shoulders relaxed'), findsOneWidget);
      await closeSession(tester);
    });

    for (final initialNotes in <String?>[null, '', ' \n ']) {
      testWidgets('adds and clears notes on an empty session ($initialNotes)', (
        tester,
      ) async {
        await startSession(tester, notes: initialNotes, withExercise: false);
        await showSession(tester);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(find.text('This session has no exercises.'), findsOneWidget);

        await tester.tap(find.byTooltip('Edit session notes'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          '  Standing Ribcage Circles  ',
        );
        await saveNotes(tester, 'Standing Ribcage Circles');
        expect(find.text('Standing Ribcage Circles'), findsOneWidget);

        await tester.tap(find.byTooltip('Edit session notes'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), ' \n ');
        await saveNotes(tester, null);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(find.text('This session has no exercises.'), findsOneWidget);
        await closeSession(tester);
      });
    }
  });

  for (final unilateral in [false, true]) {
    for (final ready in [false, true]) {
      testWidgets(
        'last-session reference and prefill (unilateral=$unilateral, ready=$ready)',
        (tester) async {
          final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
          final sessions = SessionRepository(db);
          late String sessionId;
          await tester.runAsync(() async {
            final templates = TemplateRepository(db);
            final templateId = await templates.createTemplate(name: 'Push A');
            await templates.addExercise(
              templateId,
              TemplateExerciseDraft(
                displayName: 'Press',
                orderLabel: '1',
                targetSets: 4,
                repTarget: RepTarget.reps(6, 10),
                isUnilateral: unilateral,
              ),
            );
            final previousId = await sessions.startFromTemplate(templateId);
            for (final set in (await sessions.readGrid(previousId)).single.sets) {
              final reps = !ready && set.setNumber == 4 ? 9 : 10;
              await sessions.saveSet(
                set.id,
                weight: 70,
                reps: unilateral ? null : reps,
                leftReps: unilateral ? 10 : null,
                rightReps: unilateral ? reps : null,
              );
            }
            await sessions.completeSession(previousId);
            sessionId = await sessions.startFromTemplate(templateId);
          });

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                databaseProvider.overrideWithValue(db),
                notificationServiceProvider.overrideWithValue(_Notifications()),
                watchServiceProvider.overrideWithValue(_Watch()),
                authControllerProvider.overrideWith(_LocalAuth.new),
              ],
              child: MaterialApp(
                home: ActiveSessionScreen(sessionId: sessionId),
              ),
            ),
          );
          await tester.runAsync(() async {
            await sessions.watchGrid(sessionId).first;
          });
          await tester.pumpAndSettle();
          final summary = unilateral
              ? 'Last: 70 lb × L10/R10, L10/R10, L10/R10, L10/R${ready ? 10 : 9}'
              : 'Last: 70 lb × 10, 10, 10, ${ready ? 10 : 9}';
          expect(find.text(summary), findsOneWidget);
          final badge = find.text('Ready to progress (+weight)');
          expect(badge, ready ? findsOneWidget : findsNothing);

          await tester.tap(find.text('Set 1').first);
          await tester.pumpAndSettle();

          expect(find.text(summary), findsNWidgets(2));
          expect(badge, ready ? findsNWidgets(2) : findsNothing);
          final weight = find.widgetWithText(TextField, 'Weight (lb)');
          expect(tester.widget<TextField>(weight).controller!.text, '70');
          final reps = find.widgetWithText(
            TextField,
            unilateral ? 'Left reps' : 'Reps',
          );
          expect(tester.widget<TextField>(reps).controller!.text, isEmpty);
          // The suggestion is only an input default; opening the sheet writes nothing.
          await tester.runAsync(() async {
            expect(
              (await sessions.readGrid(sessionId)).single.sets.first.weight,
              isNull,
            );
          });

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(db.close);
        },
      );
    }
  }

  testWidgets('paired set logging keeps each exercise rest on resume', (
    tester,
  ) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final sessions = SessionRepository(db);
    final notifications = _Notifications();
    late String sessionId;
    await tester.runAsync(() async {
      final templates = TemplateRepository(db);
      final templateId = await templates.createTemplate(name: 'Paired sets');
      for (final (label, name, rest) in [
        ('1A', 'Bench Press', 90),
        ('1B', 'Weighted Chin-Up', 60),
      ]) {
        await templates.addExercise(
          templateId,
          TemplateExerciseDraft(
            displayName: name,
            orderLabel: label,
            restSeconds: rest,
          ),
        );
      }
      sessionId = await sessions.startFromTemplate(templateId);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(notifications),
          watchServiceProvider.overrideWithValue(_Watch()),
          authControllerProvider.overrideWith(_LocalAuth.new),
        ],
        child: MaterialApp(home: ActiveSessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(() async {
      await sessions.watchGrid(sessionId).first;
    });
    await tester.pumpAndSettle();
    final a = find.byWidgetPredicate(
      (widget) =>
          widget is SessionExerciseCard &&
          widget.row.exercise.orderLabel == '1A',
    );
    await tester.tap(
      find.descendant(of: a, matching: find.text('Set 1')).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ActiveSessionScreen)),
    );
    ActiveTimer? timer;
    // Drain both Flutter's frame queue and Drift's database futures.
    for (var attempt = 0; attempt < 20 && timer == null; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      timer = await tester.runAsync<ActiveTimer?>(
        () => container.refresh(activeTimerProvider.future),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(timer?.label, '1B · Weighted Chin-Up (Set 1)');
    expect(timer?.durationSeconds, 90);
    expect(notifications.body, 'Next: 1B · Weighted Chin-Up (Set 1)');
    await tester.runAsync(() async {
      final set = (await sessions.readGrid(sessionId)).first.sets.first;
      expect(set.rpe, isNull);
      expect(set.partials, isNull);
    });
    final b = find.byWidgetPredicate(
      (widget) =>
          widget is SessionExerciseCard &&
          widget.row.exercise.orderLabel == '1B',
    );
    expect(find.descendant(of: b, matching: find.text('Next')), findsOneWidget);
    expect(
      find.descendant(of: a, matching: find.textContaining('since last set')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: b, matching: find.textContaining('since last set')),
      findsNothing,
    );

    await tester.tap(
      find.descendant(of: b, matching: find.text('Set 1')).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log set'));
    final exerciseA = tester.widget<SessionExerciseCard>(a).row.exercise.id;
    for (
      var attempt = 0;
      attempt < 20 && timer?.sessionExerciseId != exerciseA;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
      timer = await tester.runAsync<ActiveTimer?>(
        () => container.refresh(activeTimerProvider.future),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(timer?.sessionExerciseId, exerciseA);
    expect(timer?.durationSeconds, 60);
    for (final card in [a, b]) {
      expect(
        find.descendant(
          of: card,
          matching: find.textContaining('since last set'),
        ),
        findsOneWidget,
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(notifications),
          watchServiceProvider.overrideWithValue(_Watch()),
          authControllerProvider.overrideWith(_LocalAuth.new),
        ],
        child: MaterialApp(home: ActiveSessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(() async {
      await sessions.watchGrid(sessionId).first;
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('since last set'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  });

  group('session snapshot states', () {
    Future<void> seedSession(
      QuadrilleDatabase db, {
      required String name,
      required String notes,
      required String exerciseName,
    }) async {
      final now = DateTime(2026, 1, 5, 12);
      await db
          .into(db.workoutSessions)
          .insert(
            WorkoutSessionsCompanion.insert(
              id: 'session',
              name: name,
              generalNotes: Value(notes),
              status: const Value(SessionStatus.active),
              startedAt: now,
              createdAt: now,
              updatedAt: now,
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
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.setEntries)
          .insert(
            SetEntriesCompanion.insert(
              id: 'set-1',
              sessionExerciseId: 'exercise',
              setNumber: 1,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    for (final fail in [false, true]) {
      testWidgets(
        fail
            ? 'falls back to default title and omits notes card on reload error'
            : 'falls back to default title and omits notes card while reloading',
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
              notificationServiceProvider.overrideWithValue(_Notifications()),
              watchServiceProvider.overrideWithValue(_Watch()),
              authControllerProvider.overrideWith(_LocalAuth.new),
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
            await seedSession(
              a,
              name: 'Push A',
              notes: 'Profile A notes',
              exerciseName: 'Bench Press',
            );
            await seedSession(
              b,
              name: 'Pull B',
              notes: 'Profile B notes',
              exerciseName: 'Barbell Row',
            );
          });

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(
                home: ActiveSessionScreen(sessionId: 'session'),
              ),
            ),
          );
          await settle(tester);

          expect(find.text('Push A'), findsOneWidget);
          expect(find.text('Workout'), findsNothing);
          expect(find.byType(SessionNotesCard), findsOneWidget);
          expect(find.text('Profile A notes'), findsOneWidget);
          expect(find.text('Bench Press'), findsOneWidget);

          container.read(currentProfileProvider.notifier).set('b');
          await settle(tester);

          expect(container.read(sessionProvider('session')).isLoading, isTrue);
          expect(find.text('Barbell Row'), findsOneWidget);
          expect(find.text('Workout'), findsOneWidget);
          expect(find.text('Push A'), findsNothing);
          expect(find.byType(SessionNotesCard), findsNothing);
          expect(find.text('Profile A notes'), findsNothing);

          if (fail) {
            bRepo.firstEmission.completeError(StateError('Read failure'));
            await settle(tester);
            expect(container.read(sessionProvider('session')).hasError, isTrue);
            expect(find.text('Workout'), findsOneWidget);
            expect(find.text('Push A'), findsNothing);
            expect(find.byType(SessionNotesCard), findsNothing);
            expect(find.text('Profile A notes'), findsNothing);
          } else {
            bRepo.firstEmission.complete();
            await settle(tester);
            expect(find.text('Pull B'), findsOneWidget);
            expect(find.text('Workout'), findsNothing);
            expect(find.byType(SessionNotesCard), findsOneWidget);
            expect(find.text('Profile B notes'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'falls back to default title and omits notes card on stream error after load',
      (tester) async {
        final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
        final repo = _ControllableSessionRepository(db);
        final container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionRepositoryProvider.overrideWithValue(repo),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            watchServiceProvider.overrideWithValue(_Watch()),
            authControllerProvider.overrideWith(_LocalAuth.new),
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
          () => seedSession(
            db,
            name: 'Push A',
            notes: 'Loaded notes',
            exerciseName: 'Bench Press',
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: ActiveSessionScreen(sessionId: 'session'),
            ),
          ),
        );
        await settle(tester);

        expect(find.text('Push A'), findsOneWidget);
        expect(find.byType(SessionNotesCard), findsOneWidget);
        expect(find.text('Loaded notes'), findsOneWidget);

        repo.errors.add(StateError('Stream read failed'));
        await settle(tester);

        expect(container.read(sessionProvider('session')).hasError, isTrue);
        expect(find.text('Bench Press'), findsOneWidget);
        expect(find.text('Workout'), findsOneWidget);
        expect(find.text('Push A'), findsNothing);
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
