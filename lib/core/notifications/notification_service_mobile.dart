import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notification_service.dart';

NotificationService createNotificationService() => _MobileNotificationService();

/// iOS/Android rest-complete notifications via flutter_local_notifications.
///
/// Schedules an OS-level notification at the absolute deadline — the reliable
/// way to buzz the phone (and a paired watch) when it's in a pocket, since
/// background Dart timers are unreliable on mobile. Android uses an exact alarm
/// so the buzz lands on time.
class _MobileNotificationService implements NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  // Monotonic epoch incremented on each owned schedule/cancel so stale calls
  // exit after awaits instead of issuing outdated platform operations.
  int _epoch = 0;
  static const int _notificationId = 1001;
  static const String _channelId = 'rest_timer';

  Future<void> _ensureInit() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin),
    );
    _initialized = true;
  }

  @override
  Future<bool> ensurePermission() async {
    await _ensureInit();
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission() ?? false;
      // To-the-second delivery needs the exact-alarm permission on Android 13+.
      await android?.requestExactAlarmsPermission();
      return granted;
    }
    if (Platform.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return false;
  }

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
    bool voiceCuesEnabled = false,
  }) async {
    final epoch = ++_epoch;
    await _ensureInit();
    if (epoch != _epoch) return;
    await _plugin.cancel(id: _notificationId);
    if (epoch != _epoch) return;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        voiceCuesEnabled ? 'rest_timer_voice_v1' : _channelId,
        voiceCuesEnabled ? 'Rest timer voice cues' : 'Rest timer',
        channelDescription: 'Alerts when a rest period is complete',
        sound: voiceCuesEnabled
            ? const RawResourceAndroidNotificationSound('rest_complete')
            : null,
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
      ),
      iOS: DarwinNotificationDetails(
        presentSound: true,
        sound: voiceCuesEnabled ? 'rest_complete.wav' : null,
      ),
    );

    final when = tz.TZDateTime.from(endsAt, tz.local);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
      return;
    }
    await _plugin.zonedSchedule(
      id: _notificationId,
      title: title,
      body: body,
      scheduledDate: when,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    if (stillOwned != null && !stillOwned()) return;
    final epoch = ++_epoch;
    await _ensureInit();
    if (epoch != _epoch || (stillOwned != null && !stillOwned())) return;
    await _plugin.cancel(id: _notificationId);
  }
}
