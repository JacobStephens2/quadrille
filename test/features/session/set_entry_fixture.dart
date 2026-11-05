import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/set_entry_controller.dart';
import 'package:quadrille/features/session/presentation/set_entry_sheet.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/timer/timer_providers.dart';
import 'package:quadrille/features/watch/watch_providers.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

List<Object?> recordHaptics(WidgetTester tester) {
  final haptics = <Object?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

/// Real logging and Drift, with controllable persistence and notification edges.
class EntryFixture {
  EntryFixture._(this.db, this.sessions, this.row);

  final QuadrilleDatabase db;
  final EntryRepository sessions;
  final SessionGridRow row;
  final notifications = EntryNotifications();
  final watch = EntryWatch();
  final navigation = EntryNavigation();
  DateTime now = DateTime(2026);
  late final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      sessionRepositoryProvider.overrideWithValue(sessions),
      setEntryNowProvider.overrideWithValue(() => now),
      notificationServiceProvider.overrideWithValue(notifications),
      watchServiceProvider.overrideWithValue(watch),
      authControllerProvider.overrideWith(_LocalAuth.new),
    ],
  );

  static Future<EntryFixture> create(
    WidgetTester tester, {
    bool timed = true,
    bool unilateral = false,
    int restSeconds = 30,
    LoadKind loadKind = LoadKind.externalWeight,
    RepTarget? target,
  }) async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    final sessions = EntryRepository(db);
    final row = await tester.runAsync(() async {
      final templates = TemplateRepository(db);
      final id = await templates.createTemplate(name: 'Entry');
      await templates.addExercise(
        id,
        TemplateExerciseDraft(
          displayName: 'Exercise',
          orderLabel: '1',
          targetSets: 2,
          restSeconds: restSeconds,
          isUnilateral: unilateral,
          loadKind: loadKind,
          repTarget:
              target ??
              (timed ? RepTarget.duration(2, 2) : RepTarget.reps(8, 12)),
        ),
      );
      final sessionId = await sessions.startFromTemplate(id);
      return (await sessions.readGrid(sessionId)).single;
    });
    final fixture = EntryFixture._(db, sessions, row!);
    addTearDown(() async {
      fixture.container.dispose();
      await tester.pump(Duration.zero);
      await tester.runAsync(db.close);
    });
    return fixture;
  }

  SetEntrySeed seed([SessionGridRow? current]) =>
      SetEntrySeed(row: current ?? row, set: (current ?? row).sets.first);

  Future<SetEntry> saved(WidgetTester tester) async => (await tester.runAsync(
    () => sessions.readGrid(row.exercise.sessionId),
  ))!.single.sets.first;

  Future<void> finish(WidgetTester tester, Future<void> operation) async {
    await tester.runAsync(() => operation);
    await tester.pump();
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(() => sessions.readGrid(row.exercise.sessionId));
    await tester.pump();
  }

  Future<void> showSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [navigation],
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showSetEntrySheet(context, row: row, set: row.sets.first),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}

class EntryNavigation extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;
}

class EntryRepository extends SessionRepository {
  EntryRepository(super.db);

  Completer<void>? persistence;
  Object? failure;
  final writes = <SetStatus>[];

  @override
  Future<void> saveSet(
    String setEntryId, {
    double? weight,
    int? reps,
    int? leftReps,
    int? rightReps,
    double? rpe,
    int? partials,
    String? notes,
    SetStatus status = SetStatus.completed,
  }) async {
    writes.add(status);
    await persistence?.future;
    if (failure != null) throw failure!;
    await super.saveSet(
      setEntryId,
      weight: weight,
      reps: reps,
      leftReps: leftReps,
      rightReps: rightReps,
      rpe: rpe,
      partials: partials,
      notes: notes,
      status: status,
    );
  }
}

class EntryNotifications implements NotificationService {
  Completer<bool>? permission;
  Object? failure;
  int requests = 0;
  final bodies = <String>[];

  @override
  Future<bool> ensurePermission() async {
    requests++;
    await permission?.future;
    if (failure != null) throw failure!;
    return true;
  }

  @override
  void scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) => bodies.add(body);

  @override
  void cancel() {}
}

class EntryWatch implements WatchService {
  final snapshots = <WatchSnapshot>[];

  @override
  void updateSnapshot(WatchSnapshot snapshot) => snapshots.add(snapshot);

  @override
  void clear() {}
}

class _LocalAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}
