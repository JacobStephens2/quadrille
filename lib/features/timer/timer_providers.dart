import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/providers.dart';
import '../push/push_providers.dart';
import '../settings/settings_providers.dart';
import '../watch/watch_providers.dart';
import '../watch/watch_snapshot.dart';
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

/// Coordinates the persisted deadline, the OS/browser notification, the watch
/// snapshot, and (on web, when sync is configured) a server-scheduled push.
class RestTimerController {
  RestTimerController(this._ref);

  final Ref _ref;

  TimerRepository get _repo => _ref.read(timerRepositoryProvider);
  NotificationService get _notifications =>
      _ref.read(notificationServiceProvider);

  String _body(String? label) =>
      label == null ? 'Time for your next set.' : 'Next: $label';

  /// Starts a rest countdown and schedules the "rest complete" alerts.
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
      body: _body(label),
    );
    _ref.read(watchServiceProvider).updateSnapshot(
          WatchSnapshot(
            exerciseName: label ?? 'Rest',
            restEndsAtMillis: endsAt.millisecondsSinceEpoch,
          ),
        );
    await _scheduleWebPush(endsAt, label);
  }

  /// Extends (+) or shortens (−) the running timer and reschedules its alerts.
  Future<void> adjust(Duration delta) async {
    final endsAt = await _repo.adjust(delta);
    if (endsAt == null) return;
    final timer = await _repo.read();
    final label = timer?.label;
    _notifications.scheduleRestComplete(
      endsAt: endsAt,
      title: 'Rest complete',
      body: _body(label),
    );
    await _scheduleWebPush(endsAt, label);
  }

  /// Ends the timer early and cancels its alerts.
  Future<void> skip() async {
    await _repo.clear();
    _notifications.cancel();
    _ref.read(watchServiceProvider).clear();
    await _cancelWebPush();
  }

  /// Schedules a server-sent push (web only, and only when sync is configured —
  /// it reuses the sync endpoint + token). No-op otherwise.
  Future<void> _scheduleWebPush(DateTime endsAt, String? label) async {
    final s = await _ref.read(settingsRepositoryProvider).read();
    final token = s.syncToken;
    if (token == null || token.isEmpty) return;
    await _ref.read(webPushServiceProvider).scheduleRest(
          endpoint: s.syncEndpoint,
          token: token,
          endsAt: endsAt,
          title: 'Rest complete',
          body: _body(label),
        );
  }

  Future<void> _cancelWebPush() async {
    final s = await _ref.read(settingsRepositoryProvider).read();
    final token = s.syncToken;
    if (token == null || token.isEmpty) return;
    await _ref
        .read(webPushServiceProvider)
        .cancel(endpoint: s.syncEndpoint, token: token);
  }
}

final restTimerControllerProvider = Provider<RestTimerController>((ref) {
  return RestTimerController(ref);
});
