import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The clock boundary for the sheet's transient hold countdown.
final holdTimerNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

@immutable
class HoldTimerState {
  const HoldTimerState({
    this.remainingSeconds,
    this.isRunning = false,
    this.autoLog = false,
    this.secondsError,
  });

  final int? remainingSeconds;
  final bool isRunning;
  final bool autoLog;
  final String? secondsError;
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

  void setAutoLog(bool value) {
    state = HoldTimerState(
      remainingSeconds: state.remainingSeconds,
      isRunning: state.isRunning,
      autoLog: value,
      secondsError: state.secondsError,
    );
  }

  void start(String enteredSeconds, {required Future<void> Function() logSet}) {
    final seconds = int.tryParse(enteredSeconds.trim());
    if (seconds == null || seconds <= 0) {
      state = HoldTimerState(
        autoLog: state.autoLog,
        secondsError: 'Enter seconds greater than zero',
      );
      return;
    }
    _ticker?.cancel();
    _endsAt = ref.read(holdTimerNowProvider)().add(Duration(seconds: seconds));
    state = HoldTimerState(
      remainingSeconds: seconds,
      isRunning: true,
      autoLog: state.autoLog,
    );
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
          autoLog: state.autoLog,
        );
      }
      if (remaining == 0) {
        unawaited(HapticFeedback.heavyImpact());
        if (state.autoLog) unawaited(logSet());
      }
    });
  }

  void stop() {
    _ticker?.cancel();
    _endsAt = null;
    state = HoldTimerState(autoLog: state.autoLog);
  }
}

final holdTimerProvider = NotifierProvider.autoDispose
    .family<HoldTimerController, HoldTimerState, String>(
      (_) => HoldTimerController(),
    );
