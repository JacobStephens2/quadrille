import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/providers.dart';
import 'data/timer_repository.dart';

final timerRepositoryProvider = Provider<TimerRepository>((ref) {
  return TimerRepository(ref.watch(databaseProvider));
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return createNotificationService();
});

/// The active rest timer row (or null). Drives the countdown banner.
final activeTimerProvider = StreamProvider<ActiveTimer?>((ref) {
  return ref.watch(timerRepositoryProvider).watch();
});

/// Ticks a few times a second to redraw the countdown. autoDispose so it only
/// runs while something (the banner) is listening.
final timerTickProvider = StreamProvider.autoDispose<int>((ref) {
  return Stream.periodic(const Duration(milliseconds: 250), (i) => i);
});

/// Coordinates the persisted deadline and the OS/browser notification.
class RestTimerController {
  RestTimerController(this._ref);

  final Ref _ref;

  TimerRepository get _repo => _ref.read(timerRepositoryProvider);
  NotificationService get _notifications =>
      _ref.read(notificationServiceProvider);

  /// Starts a rest countdown and schedules the "rest complete" notification.
  Future<void> start({
    required Duration duration,
    String? sessionId,
    String? sessionExerciseId,
    String? label,
  }) async {
    if (duration <= Duration.zero) return;
    await _notifications.ensurePermission();
    final endsAt = await _repo.start(
      duration: duration,
      sessionId: sessionId,
      sessionExerciseId: sessionExerciseId,
      label: label,
    );
    _notifications.scheduleRestComplete(
      endsAt: endsAt,
      title: 'Rest complete',
      body: label == null ? 'Time for your next set.' : 'Next: $label',
    );
  }

  /// Extends (+) or shortens (−) the running timer and reschedules.
  Future<void> adjust(Duration delta) async {
    final endsAt = await _repo.adjust(delta);
    if (endsAt == null) return;
    final timer = await _repo.read();
    _notifications.scheduleRestComplete(
      endsAt: endsAt,
      title: 'Rest complete',
      body: timer?.label == null ? 'Time for your next set.' : 'Next: ${timer!.label}',
    );
  }

  /// Ends the timer early and cancels the notification.
  Future<void> skip() async {
    await _repo.clear();
    _notifications.cancel();
  }
}

final restTimerControllerProvider = Provider<RestTimerController>((ref) {
  return RestTimerController(ref);
});
