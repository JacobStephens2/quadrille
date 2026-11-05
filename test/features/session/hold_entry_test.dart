import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'set_entry_fixture.dart';

void main() {
  testWidgets(
    'timed entry wires seconds, countdown, stop, and auto-log controls',
    (tester) async {
      final f = await EntryFixture.create(tester);
      await f.showSheet(tester);
      final seconds = find.widgetWithText(TextField, 'Seconds');
      expect(tester.widget<TextField>(seconds).controller!.text, '2');
      expect(find.widgetWithText(TextField, 'Reps'), findsNothing);
      await tester.enterText(seconds, '3');
      await tester.tap(find.text('Start hold timer'));
      await tester.pump();
      expect(find.text('3s remaining'), findsOneWidget);
      expect(tester.widget<TextField>(seconds).enabled, isFalse);
      await tester.tap(find.text('Stop hold timer'));
      await tester.pump();
      expect(tester.widget<TextField>(seconds).enabled, isTrue);
      await tester.tap(find.text('Log set when timer finishes'));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.enterText(seconds, '0');
      await tester.tap(find.text('Start hold timer'));
      await tester.pump();
      expect(find.text('Enter seconds greater than zero'), findsOneWidget);
    },
  );

  testWidgets('automatic success dismisses the sheet once', (tester) async {
    final f = await EntryFixture.create(tester);
    await f.showSheet(tester);
    await tester.tap(find.text('Log set when timer finishes'));
    await tester.tap(find.text('Start hold timer'));
    await tester.pump();
    f.now = f.now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 250));
    await f.flush(tester);
    await tester.pumpAndSettle();
    expect(f.navigation.pops, 1);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Log set'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(f.navigation.pops, 1);
  });

  testWidgets('duration hold entry fits a mobile keyboard', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final f = await EntryFixture.create(tester);
    await f.showSheet(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Log set').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Start hold timer'));
    expect(find.text('Start hold timer').hitTestable(), findsOneWidget);
  });
}
