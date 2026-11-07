import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/history/presentation/session_history_detail_screen.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
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
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
