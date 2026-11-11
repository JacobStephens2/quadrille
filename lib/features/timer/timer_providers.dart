import 'package:drift/drift.dart' show SimpleSelectStatement, Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/domain/enums.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/providers.dart';
import '../auth/auth_controller.dart';
import '../push/push_providers.dart';
import '../watch/watch_providers.dart';
import '../watch/watch_snapshot.dart';

part 'data/timer_persistence.dart';

/// Wall clock for timer transitions; deadlines are persisted at DB precision.
final restTimerNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final _timerPersistenceProvider = Provider<_TimerPersistence>((ref) {
  return _TimerPersistence(
    ref.watch(databaseProvider),
    ref.watch(restTimerNowProvider),
  );
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return createNotificationService();
});

/// The active rest timer row (or null). Drives the countdown banner.
final activeTimerProvider = StreamProvider<ActiveTimer?>((ref) {
  return ref.watch(_timerPersistenceProvider).watch();
});

/// Ticks a few times a second to redraw the countdown. autoDispose so it only
/// runs while something (the banner) is listening.
final timerTickProvider = StreamProvider.autoDispose<int>((ref) {
  return Stream.periodic(const Duration(milliseconds: 250), (i) => i);
});

/// Orders timer transitions and alert work in invocation order. A failed
/// command reports its error to its caller and releases the next command.
/// A profile switch drops commands that have not started and opens a new
/// queue, so one profile cannot change or delay the other's timer.
/// A Local profile wipe drops a Rest timer start that has not been saved,
/// and [cancelForWipe] cancels a published alert and clears the watch the
/// same way [skip] does.
/// Completion covers adapter submission, not delivery to a device.
class RestTimerController {
  RestTimerController(this._ref);

  final Ref _ref;
  Future<void> _pending = Future<void>.value();
  _TimerPersistence? _queueStore;

  bool _owns(_TimerPersistence store) =>
      identical(store, _ref.read(_timerPersistenceProvider));

  Future<void> _enqueue(Future<void> Function(_TimerPersistence) command) {
    final store = _ref.read(_timerPersistenceProvider);
    if (!identical(store, _queueStore)) {
      _queueStore = store;
      _pending = Future<void>.value();
    }
    final result = _pending.then((_) async {
      if (!_owns(store)) return;
      await command(store);
    });
    // Recover only the queue tail; the caller still receives the original error.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  NotificationService get _notifications =>
      _ref.read(notificationServiceProvider);

  String _body(String? label) =>
      label == null ? 'Time for your next set.' : 'Next: $label';

  /// Starts a rest countdown and schedules the "rest complete" alerts.
  /// The generation is the one current when this start is invoked. A wipe
  /// that lands before the save drops the start instead of inserting it.
  /// A wipe that lands after the alert is scheduled cancels that alert and
  /// skips the watch update. A start invoked after that wipe has sealed this
  /// profile does not publish.
  Future<void> start({
    required Duration duration,
    String? sessionId,
    String? sessionExerciseId,
    String? label,
  }) {
    final persistence = _ref.read(_timerPersistenceProvider);
    if (!persistence.acceptsRestTimerWrites) return Future<void>.value();
    final generation = persistence.generation;
    return _enqueue((store) async {
      if (!store.acceptsRestTimerWrites) return;
      if (duration <= Duration.zero) return;
      if (!identical(store.generation, generation)) return;
      await _notifications.ensurePermission();
      if (!identical(store.generation, generation)) return;
      final timer = await store.start(
        duration: duration,
        generation: generation,
        sessionId: sessionId,
        sessionExerciseId: sessionExerciseId,
        label: label,
      );
      if (timer == null || !identical(store.generation, generation)) return;
      await _project(timer, store, generation);
    });
  }

  /// Schedules the rest-complete alert for this publication. When [generation]
  /// is no longer current afterwards, cancels that alert and does not publish
  /// the deadline to the watch.
  Future<void> _project(
    ActiveTimer timer,
    _TimerPersistence store,
    Object generation,
  ) async {
    await _notifications.scheduleRestComplete(
      endsAt: timer.endsAt,
      title: 'Rest complete',
      body: _body(timer.label),
    );
    if (!identical(store.generation, generation)) {
      // Cancel only while this profile still owns the shared alert. Another
      // profile may schedule into the same slot before the platform cancel.
      if (_owns(store)) {
        await _notifications.cancel(stillOwned: () => _owns(store));
      }
      return;
    }
    if (!_owns(store)) return;
    await _ref
        .read(watchServiceProvider)
        .updateSnapshot(
          WatchSnapshot(
            exerciseName: timer.label ?? 'Rest',
            restEndsAtMillis: timer.endsAt.millisecondsSinceEpoch,
          ),
        );
    if (!_owns(store)) return;
    await _scheduleWebPush(timer.endsAt, timer.label);
  }

  /// Extends (+) or shortens (−) the running timer and reschedules its alerts
  /// through the same publication as [start].
  Future<void> adjust(Duration delta) {
    final persistence = _ref.read(_timerPersistenceProvider);
    if (!persistence.acceptsRestTimerWrites) return Future<void>.value();
    final generation = persistence.generation;
    return _enqueue((store) async {
      if (!store.acceptsRestTimerWrites) return;
      if (!identical(store.generation, generation)) return;
      final timer = await store.adjust(delta: delta, generation: generation);
      if (timer == null || !identical(store.generation, generation)) return;
      await _project(timer, store, generation);
    });
  }

  /// Ends the timer early and cancels its alerts.
  Future<void> skip() => _enqueue((store) async {
    await store.clear();
    await _dismissPublished(store);
  });

  /// Cancels the published Rest timer alert and clears the watch, the same
  /// way [skip] does, without deleting a row saved later on this queue.
  /// Guest wipe queues this before it retires the write generation. Once this
  /// command finishes it seals the profile, so a start or adjust queued
  /// behind it cannot publish the shared alert. The caller finishes this
  /// before leaving the profile.
  Future<void> cancelForWipe() => _enqueue((store) async {
    await _dismissPublished(store);
    store.sealRestTimer();
  });

  Future<void> _dismissPublished(_TimerPersistence store) async {
    if (!_owns(store)) return;
    await _notifications.cancel();
    if (!_owns(store)) return;
    await _ref.read(watchServiceProvider).clear();
    if (!_owns(store)) return;
    await _cancelWebPush();
  }

  bool get _canPush =>
      _ref.read(authControllerProvider).value?.canSync ?? false;

  /// Schedules a server-sent push (web only, and only for a signed-in, verified
  /// account — authenticated by the session cookie). No-op otherwise.
  Future<void> _scheduleWebPush(DateTime endsAt, String? label) async {
    if (!_canPush) return;
    await _ref
        .read(webPushServiceProvider)
        .scheduleRest(
          endpoint: accountApiBaseUrl,
          endsAt: endsAt,
          title: 'Rest complete',
          body: _body(label),
        );
  }

  Future<void> _cancelWebPush() async {
    if (!_canPush) return;
    await _ref.read(webPushServiceProvider).cancel(endpoint: accountApiBaseUrl);
  }
}

final restTimerControllerProvider = Provider<RestTimerController>((ref) {
  return RestTimerController(ref);
});
