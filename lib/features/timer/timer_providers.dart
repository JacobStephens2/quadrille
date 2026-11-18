import 'dart:async';

import 'package:drift/drift.dart' show SimpleSelectStatement, Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/rest_voice_player.dart';
import '../../core/database/database.dart';
import '../../core/domain/enums.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/providers.dart';
import '../auth/auth_controller.dart';
import '../push/push_providers.dart';
import '../settings/data/settings_repository.dart';
import '../settings/settings_providers.dart';
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

final restVoicePlayerProvider = Provider<RestVoicePlayer>((ref) {
  final player = RestVoicePlayer();
  ref.onDispose(() => unawaited(player.dispose()));
  return player;
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
/// same way [skip] does. [suspendForProfileTransition] dismisses published
/// alerts immediately on sign-out or profile switch without waiting on pending
/// commands or deleting saved rows, and commands that lose profile ownership
/// or active write generation exit without scheduling or projecting alerts.
/// Completion covers adapter submission, not delivery to a device.
class RestTimerController {
  RestTimerController(this._ref);

  final Ref _ref;
  Future<void> _pending = Future<void>.value();
  _TimerPersistence? _queueStore;

  bool _owns(_TimerPersistence store) =>
      _ref.mounted && identical(store, _ref.read(_timerPersistenceProvider));

  Future<void> _enqueue(Future<void> Function(_TimerPersistence) command) {
    if (!_ref.mounted) return Future<void>.value();
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

  Future<void> _enqueueOwned(
    Future<void> Function(_TimerPersistence store, Object generation) command,
  ) {
    if (!_ref.mounted) return Future<void>.value();
    final persistence = _ref.read(_timerPersistenceProvider);
    if (!persistence.acceptsRestTimerWrites) return Future<void>.value();
    final generation = persistence.generation;
    return _enqueue((store) async {
      if (!_canPublish(store, generation)) return;
      await command(store, generation);
    });
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
  }) => _enqueueOwned((store, generation) async {
    if (duration <= Duration.zero) return;
    await _notifications.ensurePermission();
    if (!_canPublish(store, generation)) return;
    final timer = await store.start(
      duration: duration,
      generation: generation,
      sessionId: sessionId,
      sessionExerciseId: sessionExerciseId,
      label: label,
    );
    if (timer == null || !_canPublish(store, generation)) return;
    final settings = await SettingsRepository(store._db).read();
    if (!_canPublish(store, generation)) return;
    if (settings.voiceCuesEnabled) {
      unawaited(_ref.read(restVoicePlayerProvider).play(RestVoiceCue.start));
    }
    await _project(timer, store, generation);
  });

  bool _canPublish(_TimerPersistence store, Object generation) =>
      _owns(store) &&
      store.acceptsRestTimerWrites &&
      identical(store.generation, generation);

  /// Schedules the rest-complete alert for this publication. When [generation]
  /// is no longer current afterwards, cancels that alert and does not publish
  /// the deadline to the watch.
  Future<void> _project(
    ActiveTimer timer,
    _TimerPersistence store,
    Object generation,
  ) async {
    if (!_canPublish(store, generation)) return;
    final scheduled = await _scheduleNotification(
      timer,
      store,
      generation: generation,
    );
    if (!_canPublish(store, generation)) {
      // Cancel only while this profile still owns the shared alert and its
      // scheduling ran. Another profile may own or schedule into the slot.
      if (scheduled && _owns(store)) {
        await _notifications.cancel(stillOwned: () => _owns(store));
      }
      return;
    }
    await _ref
        .read(watchServiceProvider)
        .updateSnapshot(
          WatchSnapshot(
            exerciseName: timer.label ?? 'Rest',
            restEndsAtMillis: timer.endsAt.millisecondsSinceEpoch,
          ),
        );
    if (!_canPublish(store, generation)) {
      if (_owns(store)) {
        await _notifications.cancel(stillOwned: () => _owns(store));
        if (_owns(store)) {
          await _ref.read(watchServiceProvider).clear();
        }
      }
      return;
    }
    await _scheduleWebPush(timer, store, generation);
  }

  Future<bool> _scheduleNotification(
    ActiveTimer timer,
    _TimerPersistence store, {
    required Object generation,
  }) async {
    final settings = await SettingsRepository(store._db).read();
    if (!_canPublish(store, generation)) return false;
    await _notifications.scheduleRestComplete(
      endsAt: timer.endsAt,
      title: 'Rest complete',
      body: _body(timer.label),
      voiceCuesEnabled: settings.voiceCuesEnabled,
    );
    return true;
  }

  /// Re-arms a saved future deadline without replaying its start or an old
  /// completion. Also applies preference changes to the already pending alert.
  Future<void> refreshVoiceCues() => _enqueueOwned((store, generation) async {
    await _notifications.cancel(stillOwned: () => _owns(store));
    if (!_canPublish(store, generation)) return;
    await _ref.read(restVoicePlayerProvider).stop();
    if (!_canPublish(store, generation)) return;
    final timer = await store.read();
    if (!_canPublish(store, generation)) return;
    if (timer != null &&
        timer.endsAt.isAfter(_ref.read(restTimerNowProvider)())) {
      final scheduled = await _scheduleNotification(
        timer,
        store,
        generation: generation,
      );
      if (scheduled && !_canPublish(store, generation) && _owns(store)) {
        await _notifications.cancel(stillOwned: () => _owns(store));
      }
    }
  });

  /// Extends (+) or shortens (−) the running timer and reschedules its alerts
  /// through the same publication as [start].
  Future<void> adjust(Duration delta) =>
      _enqueueOwned((store, generation) async {
        final timer = await store.adjust(delta: delta, generation: generation);
        if (timer == null || !_canPublish(store, generation)) return;
        await _project(timer, store, generation);
      });

  /// Ends the timer early and cancels its alerts.
  Future<void> skip() => _enqueueOwned((store, generation) async {
    final cleared = await store.clear(generation: generation);
    if (!cleared || !_canPublish(store, generation)) return;
    await _dismissPublished(
      store,
      stillOwned: () => _canPublish(store, generation),
    );
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

  /// Retires the active Rest timer write generation for the current Local
  /// profile, holds new writes while [action] runs, and dismisses published
  /// alerts without deleting saved rows or waiting on pending queued
  /// commands. Used by sign-out and non-guest profile transitions before
  /// revoking the outgoing session or switching profiles.
  Future<T> suspendForProfileTransition<T>({
    required bool cancelWebPush,
    required Future<T> Function() action,
  }) async {
    if (!_ref.mounted) return action();
    final store = _ref.read(_timerPersistenceProvider);
    final release = store.holdRestTimerDuringTransition();
    try {
      await _dismissPublished(
        store,
        cancelWebPush: cancelWebPush,
        ignoreErrors: true,
      );
      return await action();
    } finally {
      release();
    }
  }

  Future<void> _dismissPublished(
    _TimerPersistence store, {
    bool cancelWebPush = true,
    bool ignoreErrors = false,
    bool Function()? stillOwned,
  }) async {
    bool owned() => stillOwned?.call() ?? _owns(store);
    Future<void> attempt(Future<void> Function() action) async {
      if (!ignoreErrors) {
        await action();
        return;
      }
      try {
        await action();
      } catch (_) {}
    }

    if (!owned()) return;
    await attempt(() => _ref.read(restVoicePlayerProvider).stop());
    if (!owned()) return;
    await attempt(() => _notifications.cancel(stillOwned: owned));
    if (!owned()) return;
    await attempt(() => _ref.read(watchServiceProvider).clear());
    if (!owned() || !cancelWebPush) return;
    await attempt(_cancelWebPush);
  }

  bool get _canPush =>
      _ref.mounted &&
      (_ref.read(authControllerProvider).value?.canSync ?? false);

  /// Schedules a server-sent push (web only, and only for a signed-in, verified
  /// account — authenticated by the session cookie). No-op otherwise.
  Future<void> _scheduleWebPush(
    ActiveTimer timer,
    _TimerPersistence store,
    Object generation,
  ) async {
    if (!_canPush || !_canPublish(store, generation)) return;
    await _ref
        .read(webPushServiceProvider)
        .scheduleRest(
          endpoint: accountApiBaseUrl,
          endsAt: timer.endsAt,
          title: 'Rest complete',
          body: _body(timer.label),
          stillOwned: () => _canPush && _canPublish(store, generation),
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

/// App-lifetime bindings, kept separate from one-off timer commands so those
/// callers do not need to retain reactive preference subscriptions.
final restVoiceCueUpdatesProvider = Provider<void>((ref) {
  void refresh() {
    unawaited(
      ref.read(restTimerControllerProvider).refreshVoiceCues().catchError((
        Object error,
      ) {
        debugPrint('Rest voice cue refresh failed: $error');
      }),
    );
  }

  ref.listen(settingsProvider, (previous, next) {
    if (previous?.value != null &&
        next.value != null &&
        previous!.value!.voiceCuesEnabled != next.value!.voiceCuesEnabled) {
      refresh();
    }
  });
  ref.listen(databaseProvider, (_, _) => refresh());
});
