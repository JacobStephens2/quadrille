import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The clock boundary for the sheet's transient hold countdown.
final holdTimerNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

@immutable
class HoldTimerState {
  const HoldTimerState({this.remainingSeconds, this.isRunning = false});

  final int? remainingSeconds;
  final bool isRunning;
}

/// A sheet-scoped deadline, independent of the post-set rest timer. Closing the
/// sheet disposes the provider and cancels its redraw ticker.
class HoldTimerController extends Notifier<HoldTimerState> {
  Timer? _ticker;
  DateTime? _endsAt;

  @override
  HoldTimerState build() {
    ref.onDispose(() => _ticker?.cancel());
    return const HoldTimerState();
  }

  void start(int seconds) {
    if (seconds <= 0) return;
    _ticker?.cancel();
    _endsAt = ref.read(holdTimerNowProvider)().add(Duration(seconds: seconds));
    state = HoldTimerState(remainingSeconds: seconds, isRunning: true);
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final milliseconds = _endsAt!
          .difference(ref.read(holdTimerNowProvider)())
          .inMilliseconds;
      final remaining = (milliseconds / 1000).ceil().clamp(0, seconds);
      if (remaining == 0) {
        _ticker?.cancel();
        _endsAt = null;
      }
      if (remaining != state.remainingSeconds) {
        state = HoldTimerState(
          remainingSeconds: remaining,
          isRunning: remaining > 0,
        );
      }
    });
  }

  void stop() {
    _ticker?.cancel();
    _endsAt = null;
    state = const HoldTimerState();
  }
}

final holdTimerProvider = NotifierProvider.autoDispose
    .family<HoldTimerController, HoldTimerState, String>(
      (_) => HoldTimerController(),
    );
