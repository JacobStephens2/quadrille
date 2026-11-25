import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/formatting/workout_duration.dart';

void main() {
  group('liveWorkoutElapsedLabel (live)', () {
    test('zero is 00:00', () {
      expect(liveWorkoutElapsedLabel(Duration.zero), '00:00');
    });

    test('under an hour is MM:SS', () {
      expect(liveWorkoutElapsedLabel(const Duration(seconds: 84)), '01:24');
      expect(
        liveWorkoutElapsedLabel(const Duration(minutes: 59, seconds: 59)),
        '59:59',
      );
    });

    test('one hour switches to H:MM:SS', () {
      expect(liveWorkoutElapsedLabel(const Duration(hours: 1)), '1:00:00');
      expect(
        liveWorkoutElapsedLabel(const Duration(hours: 1, minutes: 12, seconds: 5)),
        '1:12:05',
      );
    });

    test('over 24 hours keeps counting hours, uncapped', () {
      expect(
        liveWorkoutElapsedLabel(const Duration(hours: 25, minutes: 3)),
        '25:03:00',
      );
      expect(liveWorkoutElapsedLabel(const Duration(days: 3)), '72:00:00');
    });

    test('negative elapsed clamps to zero', () {
      expect(liveWorkoutElapsedLabel(const Duration(seconds: -5)), '00:00');
    });
  });

  group('completedWorkoutDurationLabel (history total)', () {
    final started = DateTime(2026, 1, 5, 12);

    String? label(Duration? span) => completedWorkoutDurationLabel(
      startedAt: started,
      completedAt: span == null ? null : started.add(span),
    );

    test('null completedAt omits the duration', () {
      expect(label(null), isNull);
    });

    test('completedAt before or at startedAt omits the duration', () {
      expect(label(const Duration(seconds: -1)), isNull);
      expect(label(Duration.zero), isNull);
    });

    test('under a minute is <1m, never 0m', () {
      expect(label(const Duration(seconds: 20)), '<1m');
      expect(label(const Duration(seconds: 59)), '<1m');
    });

    test('minutes round to the nearest minute', () {
      expect(label(const Duration(minutes: 48)), '48m');
      expect(label(const Duration(minutes: 48, seconds: 29)), '48m');
      expect(label(const Duration(minutes: 48, seconds: 30)), '49m');
    });

    test('an hour and up is Hh Mm, dropping zero minutes', () {
      expect(label(const Duration(minutes: 72)), '1h 12m');
      expect(label(const Duration(hours: 2)), '2h');
      expect(label(const Duration(minutes: 59, seconds: 40)), '1h');
    });

    test('over 24 hours keeps counting hours', () {
      expect(label(const Duration(hours: 25, minutes: 12)), '25h 12m');
    });
  });
}
