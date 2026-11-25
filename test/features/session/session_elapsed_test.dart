import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/features/session/presentation/session_elapsed.dart';
import 'package:quadrille/features/session/session_elapsed_provider.dart';
import 'package:quadrille/features/timer/timer_providers.dart';

void main() {
  final started = DateTime(2026, 11, 6, 12);

  testWidgets('elapsed derives from startedAt and advances with the clock', (
    tester,
  ) async {
    var now = started.add(const Duration(minutes: 12, seconds: 30));
    final container = ProviderContainer(
      overrides: [restTimerNowProvider.overrideWithValue(() => now)],
    );
    final sub = container.listen(sessionElapsedProvider(started), (_, _) {});

    expect(
      container.read(sessionElapsedProvider(started)),
      const Duration(minutes: 12, seconds: 30),
    );

    // A long gap with no ticks (backgrounded, reloaded) still measures from
    // startedAt, never from a tick count.
    now = started.add(const Duration(hours: 2));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      container.read(sessionElapsedProvider(started)),
      const Duration(hours: 2),
    );
    sub.close();
    container.dispose();
    await tester.pump();
  });

  testWidgets('a backwards clock clamps elapsed to zero', (tester) async {
    final container = ProviderContainer(
      overrides: [
        restTimerNowProvider.overrideWithValue(
          () => started.subtract(const Duration(minutes: 5)),
        ),
      ],
    );
    final sub = container.listen(sessionElapsedProvider(started), (_, _) {});

    expect(container.read(sessionElapsedProvider(started)), Duration.zero);
    await tester.pump(const Duration(milliseconds: 250));
    expect(container.read(sessionElapsedProvider(started)), Duration.zero);
    sub.close();
    container.dispose();
    await tester.pump();
  });

  testWidgets('SessionElapsed renders the label and advances on tick', (
    tester,
  ) async {
    var now = started.add(const Duration(minutes: 12, seconds: 30));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [restTimerNowProvider.overrideWithValue(() => now)],
        child: MaterialApp(
          home: Scaffold(body: SessionElapsed(startedAt: started)),
        ),
      ),
    );
    expect(find.text('Elapsed 12:30'), findsOneWidget);

    now = started.add(const Duration(hours: 1, seconds: 5));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('Elapsed 1:00:05'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
