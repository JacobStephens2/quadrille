import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../timer/timer_providers.dart';

/// Live overall length of a workout, derived from its saved `startedAt`
/// (Session starting) and the wall clock on each tick. Ticks only request a
/// redraw - elapsed is never counted - so it stays correct across
/// backgrounding, reload and process death, like the rest timers. A
/// backwards clock clamps to zero; a stale session resumed days later shows
/// its true elapsed, uncapped.
final sessionElapsedProvider = Provider.autoDispose.family<Duration, DateTime>((
  ref,
  startedAt,
) {
  ref.watch(timerTickProvider);
  final elapsed = ref.watch(restTimerNowProvider)().difference(startedAt);
  return elapsed.isNegative ? Duration.zero : elapsed;
});
