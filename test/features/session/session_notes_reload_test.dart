import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/features/session/presentation/session_notes.dart';
import 'package:quadrille/features/session/session_providers.dart';

import 'session_notes_fixture.dart';
import 'session_starting_fixture.dart' show drain;

class DelayedSessionRepository extends NotesRepository {
  DelayedSessionRepository(super.db);

  final firstEmission = Completer<void>();

  @override
  Stream<WorkoutSession?> watchSession(String id) async* {
    await firstEmission.future;
    yield* super.watchSession(id);
  }
}

void main() {
  for (final fail in [false, true]) {
    testWidgets(
      fail
          ? 'failed profile reload never admits the previous profile snapshot'
          : 'profile reload never saves the previous profile snapshot',
      (tester) async {
        final fixture = NotesFixture();
        await tester.runAsync(fixture.open);
        final delayedB = DelayedSessionRepository(fixture.b);
        addTearDown(() async {
          if (!delayedB.firstEmission.isCompleted) {
            delayedB.firstEmission.complete();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(fixture.close);
        });
        await tester.runAsync(() async {
          await fixture.aRepository.setSessionNotes(
            'session',
            'Profile A notes',
          );
          await fixture.bRepository.setSessionNotes(
            'session',
            'Profile B notes',
          );
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: const MaterialApp(
              home: Scaffold(body: SessionNotesAction(sessionId: 'session')),
            ),
          ),
        );
        await drain(tester);
        fixture.replacement = delayedB;
        fixture.switchToB();
        await tester.pumpAndSettle();
        expect(
          fixture.container.read(sessionProvider('session')).isLoading,
          isTrue,
        );

        final action = find.byWidgetPredicate(
          (widget) =>
              widget is IconButton && widget.tooltip == 'Edit session notes',
        );
        final button = tester.widget<IconButton>(action);
        if (button.onPressed != null) {
          await tester.tap(find.byTooltip('Edit session notes'));
          await tester.pumpAndSettle();
          final save = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save'),
          );
          if (save.onPressed != null) {
            await tester.tap(find.text('Save'));
            await drain(tester);
          }
        }
        expect(
          await tester.runAsync(() => fixture.notes(fixture.bRepository)),
          'Profile B notes',
          reason:
              'A loading previous-profile snapshot must not acquire B ownership',
        );
        expect(
          await tester.runAsync(() => fixture.notes(fixture.aRepository)),
          'Profile A notes',
        );

        if (fail) {
          delayedB.firstEmission.completeError(
            StateError('Controlled read failure'),
          );
          await drain(tester);
          expect(
            fixture.container.read(sessionProvider('session')).hasError,
            isTrue,
          );
          expect(tester.widget<IconButton>(action).onPressed, isNull);
        } else {
          delayedB.firstEmission.complete();
          await drain(tester);
          expect(tester.widget<IconButton>(action).onPressed, isNotNull);
          await tester.tap(find.byTooltip('Edit session notes'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'Profile B notes',
          );
          await tester.enterText(find.byType(TextField), 'Edited in B');
          await tester.tap(find.text('Save'));
          await drain(tester);
          expect(
            await tester.runAsync(() => fixture.notes(fixture.bRepository)),
            'Edited in B',
          );
          expect(
            await tester.runAsync(() => fixture.notes(fixture.aRepository)),
            'Profile A notes',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
