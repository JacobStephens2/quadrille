import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/history/presentation/history_screen.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';

import '../exercises/history_fixture.dart';

void main() {
  testWidgets(
    'cancel preserves history; confirm deletes only the chosen workout',
    (tester) async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      final sessions = SessionRepository(db);
      late String chosen;
      late String other;
      await tester.runAsync(() async {
        final templates = TemplateRepository(db);
        chosen = await sessions.startFromTemplate(
          await templates.createTemplate(name: 'Push A'),
        );
        await sessions.completeSession(chosen);
        other = await sessions.startFromTemplate(
          await templates.createTemplate(name: 'Pull A'),
        );
        await sessions.completeSession(other);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await drain(tester);
      final chosenTile = find.widgetWithText(ListTile, 'Push A');
      final delete = find.descendant(
        of: chosenTile,
        matching: find.byTooltip('Delete workout'),
      );
      expect(delete, findsOneWidget);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete workout?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(chosenTile, findsOneWidget);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await drain(tester);
      expect(find.text('Push A'), findsNothing);
      expect(find.text('Pull A'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(() async {
        expect((await sessions.watchHistory().first).map((s) => s.id), [other]);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets('deleting the last workout shows empty history at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      await tester.runAsync(() => HistoryFixture(db).workout('only'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await drain(tester);
      await tester.tap(find.byTooltip('Delete workout'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Push only'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('2026'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await drain(tester);
      expect(find.text('No completed workouts yet'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'obsolete confirmation cannot delete after a profile round trip',
    (tester) async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      await tester.runAsync(() => HistoryFixture(db).workout('only'));
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await drain(tester);
      await tester.tap(find.byTooltip('Delete workout'));
      await tester.pumpAndSettle();
      container.read(currentProfileProvider.notifier).set('other');
      container.read(currentProfileProvider.notifier).set(localProfileName);
      await tester.tap(find.text('Delete'));
      await drain(tester);
      expect(find.textContaining('local profile changed'), findsOneWidget);
      await tester.runAsync(() async {
        expect(await SessionRepository(db).watchHistory().first, hasLength(1));
      });
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a failed deletion rolls back, shows an error and can retry', (
    tester,
  ) async {
    final control = DeleteWriteControl();
    final db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(control),
    );
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(() => HistoryFixture(db).workout('only'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: HistoryScreen()),
      ),
    );
    await drain(tester);
    await tester.tap(find.byTooltip('Delete workout'));
    await tester.pumpAndSettle();
    control.fail = true;
    await tester.tap(find.text('Delete'));
    await drain(tester);
    expect(
      find.text('Could not delete workout. Please try again.'),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      expect(await SessionRepository(db).watchHistory().first, hasLength(1));
      expect(await SessionRepository(db).readGrid('only'), hasLength(1));
    });
    control.fail = false;
    await tester.tap(find.text('Delete'));
    await drain(tester);
    expect(find.text('No completed workouts yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('pending deletion disables confirmation and cancellation', (
    tester,
  ) async {
    final control = DeleteWriteControl();
    final db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(control),
    );
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(() => HistoryFixture(db).workout('only'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: HistoryScreen()),
      ),
    );
    await drain(tester);
    await tester.tap(find.byTooltip('Delete workout'));
    await tester.pumpAndSettle();
    control.release = Completer<void>();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.runAsync(() => control.entered.future);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Deleting…'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );
    control.release!.complete();
    await drain(tester);
    expect(find.text('No completed workouts yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

class DeleteWriteControl extends QueryInterceptor {
  bool fail = false;
  Completer<void>? release;
  final entered = Completer<void>();

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('session_exercises')) {
      if (fail) throw StateError('Disk full');
      final pending = release;
      if (pending != null) {
        if (!entered.isCompleted) entered.complete();
        await pending.future;
      }
    }
    return super.runUpdate(executor, statement, args);
  }
}
