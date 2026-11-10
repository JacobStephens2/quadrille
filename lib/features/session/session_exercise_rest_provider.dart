import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../timer/timer_providers.dart';

/// Per-exercise display state derived from a saved completion and wall clock.
/// Ticks request a redraw; missed ticks never change the measured rest.
final sessionExerciseRestProvider = Provider.autoDispose
    .family<
      ({Duration elapsed, Duration remaining}),
      ({DateTime completedAt, Duration rest})
    >((ref, start) {
      ref.watch(timerTickProvider);
      final sinceLastSet = ref
          .watch(restTimerNowProvider)()
          .difference(start.completedAt);
      final elapsed = sinceLastSet.isNegative ? Duration.zero : sinceLastSet;
      final remaining = start.rest - elapsed;
      return (
        elapsed: elapsed,
        remaining: remaining <= Duration.zero
            ? Duration.zero
            : Duration(
                seconds:
                    (remaining.inMicroseconds / Duration.microsecondsPerSecond)
                        .ceil(),
              ),
      );
    });
