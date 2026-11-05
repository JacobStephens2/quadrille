import 'notification_service.dart';

/// No-op notifications for platforms without a notification adapter.
NotificationService createNotificationService() => _NoopNotificationService();

class _NoopNotificationService implements NotificationService {
  @override
  Future<bool> ensurePermission() async => false;

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancel() async {}
}
