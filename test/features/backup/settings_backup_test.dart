import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/features/settings/presentation/settings_screen.dart';

import 'backup_transfer_fixture.dart';

Future<void> drain(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late TransferFixture fixture;
  late ValueNotifier<bool> visible;

  setUp(() async {
    fixture = TransferFixture();
    await fixture.open();
    fixture.platform.downloadAvailable = false;
    visible = ValueNotifier(true);
  });

  tearDown(() async {
    visible.dispose();
    await fixture.close();
  });

  Future<void> showSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, showing, _) => showing
                ? const SettingsScreen()
                : const Scaffold(body: Text('Elsewhere')),
          ),
        ),
      ),
    );
    await drain(tester);
    await tester.scrollUntilVisible(find.text('Import backup'), 250);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  Future<void> openPaste(WidgetTester tester) async {
    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();
    expect(find.text('Paste backup JSON'), findsOneWidget);
    await tester.enterText(find.byType(TextField), emptyBackup);
  }

  Future<void> acceptPaste(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
  }

  void expectControls(WidgetTester tester, {required bool disabled}) {
    for (final label in ['Export backup', 'Import backup']) {
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
      );
      expect(tile.onTap, disabled ? isNull : isNotNull);
    }
  }

  testWidgets('restore opened in A never replaces B after a profile switch', (
    tester,
  ) async {
    await showSettings(tester);
    await openPaste(tester);
    fixture.switchTo('b');
    await acceptPaste(tester);
    // Continue through confirmation on master to reproduce the destructive write.
    if (find.text('Replace all data?').evaluate().isNotEmpty) {
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    }
    await drain(tester);
    await tester.runAsync(() async {
      expect(await fixture.names(fixture.b), ['B original']);
      expect(await fixture.names(fixture.a), ['A original']);
    });
    expect(find.textContaining('Restored '), findsNothing);
    expect(find.text('Replace all data?'), findsNothing);
    expectControls(tester, disabled: false);
  });

  testWidgets(
    'profile switch during replacement confirmation preserves both profiles',
    (tester) async {
      await showSettings(tester);
      await openPaste(tester);
      await acceptPaste(tester);
      expect(find.text('Replace all data?'), findsOneWidget);
      fixture.switchTo('b');
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
      await drain(tester);
      await tester.runAsync(() async {
        expect(await fixture.names(fixture.a), ['A original']);
        expect(await fixture.names(fixture.b), ['B original']);
      });
      expect(find.textContaining('Restored '), findsNothing);
    },
  );

  testWidgets(
    'restore disables both actions while pending and shows current feedback',
    (tester) async {
      await showSettings(tester);
      await openPaste(tester);
      expectControls(tester, disabled: true);
      await acceptPaste(tester);
      expectControls(tester, disabled: true);
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
      await drain(tester);
      expect(
        find.text('Restored 0 exercises, 0 templates, 0 sessions.'),
        findsOneWidget,
      );
      expectControls(tester, disabled: false);
      await tester.runAsync(() async {
        expect(await fixture.names(fixture.a), isEmpty);
        expect(await fixture.names(fixture.b), ['B original']);
      });
    },
  );

  testWidgets(
    'export claims pending synchronously and disables both actions until current feedback',
    (tester) async {
      await showSettings(tester);
      final wait = fixture.platform.copying = TransferWait();
      await tester.tap(find.text('Export backup'));
      expect(fixture.transfer.isPending, isTrue);
      await tester.runAsync(() => wait.entered.future);
      await tester.pump();
      expectControls(tester, disabled: true);
      wait.completion.complete();
      await drain(tester);
      expectControls(tester, disabled: false);
      expect(find.text('Backup copied to clipboard'), findsOneWidget);
    },
  );

  for (final retirement in ['screen removal', 'profile change']) {
    testWidgets('export suppresses feedback after $retirement', (tester) async {
      await showSettings(tester);
      final wait = fixture.platform.copying = TransferWait();
      final transfer = fixture.transfer;
      await tester.tap(find.text('Export backup'));
      await tester.runAsync(() => wait.entered.future);
      if (retirement == 'screen removal') {
        visible.value = false;
      } else {
        fixture.switchTo('b');
      }
      await tester.pumpAndSettle();
      wait.completion.complete();
      await drain(tester);
      expect(transfer.isPending, isFalse);
      expect(find.text('Backup copied to clipboard'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('accepted restore suppresses feedback after $retirement', (
      tester,
    ) async {
      await showSettings(tester);
      final wait = fixture.waits.deleting = TransferWait();
      await openPaste(tester);
      await acceptPaste(tester);
      final transfer = fixture.transfer;
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
      await tester.runAsync(() => wait.entered.future);
      if (retirement == 'screen removal') {
        visible.value = false;
      } else {
        fixture.switchTo('b');
      }
      await tester.pumpAndSettle();
      wait.completion.complete();
      await drain(tester);
      expect(transfer.isPending, isFalse);
      expect(find.textContaining('Restored '), findsNothing);
      await tester.runAsync(() async {
        expect(await fixture.names(fixture.a), isEmpty);
        expect(await fixture.names(fixture.b), ['B original']);
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clipboard errors show a concise failure and allow retry', (
    tester,
  ) async {
    await showSettings(tester);
    fixture.platform.copyError = StateError('Clipboard unavailable');
    await tester.tap(find.text('Export backup'));
    await drain(tester);
    expect(find.text('Export failed. Please try again.'), findsOneWidget);
    expectControls(tester, disabled: false);
    fixture.platform.copyError = null;
    ScaffoldMessenger.of(
      tester.element(find.byType(SettingsScreen)),
    ).clearSnackBars();
    await tester.tap(find.text('Export backup'));
    await drain(tester);
    expect(find.text('Backup copied to clipboard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
