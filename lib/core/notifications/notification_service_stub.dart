import 'notification_service.dart';

/// No-op notifications for platforms without a web Notification API. Mobile
/// delivery (flutter_local_notifications with exact alarms) is added when it
/// can be verified on a real device.
NotificationService createNotificationService() => _NoopNotificationService();

class _NoopNotificationService implements NotificationService {
  @override
  Future<bool> ensurePermission() async => false;

  @override
  void scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) {}

  @override
  void cancel() {}
}
