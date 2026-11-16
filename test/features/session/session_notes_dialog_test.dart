import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/features/history/presentation/session_history_detail_screen.dart';

import 'session_notes_fixture.dart';
import 'session_starting_fixture.dart' show drain;

void main() {
  testWidgets(
    'notes completion preserves a root cover and stays silent on return',
    (tester) async {
      final fixture = NotesFixture();
      await tester.runAsync(fixture.open);
      addTearDown(() => tester.runAsync(fixture.close));
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            navigatorKey: navigator,
            home: const SessionHistoryDetailScreen(sessionId: 'session'),
          ),
        ),
      );
      await drain(tester);
      await tester.tap(find.byTooltip('Edit session notes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Captured notes');
      final gate = NotesWrite();
      fixture.aRepository.waiting = gate;
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.runAsync(() => gate.entered.future);
      unawaited(
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (_) => const AlertDialog(title: Text('Cover survives')),
        ),
      );
      await tester.pumpAndSettle();
      gate.completion.complete();
      await drain(tester);
      expect(find.text('Cover survives'), findsOneWidget);
      expect(
        await tester.runAsync(() => fixture.notes(fixture.aRepository)),
        'Captured notes',
      );
      expect(
        await tester.runAsync(() => fixture.notes(fixture.bRepository)),
        'Original',
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
