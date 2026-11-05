/// A thin, platform-abstracted notification surface for "rest complete".
///
/// Mobile schedules OS-level notifications; web schedules browser alerts.
/// Unsupported platforms use a no-op adapter. Completion covers scheduling
/// or cancellation work, not delivery of the alert.
library;

export 'notification_service_stub.dart'
    if (dart.library.io) 'notification_service_mobile.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';

abstract interface class NotificationService {
  /// Requests permission if needed; returns true when notifications are usable.
  Future<bool> ensurePermission();

  /// Schedules a one-shot notification to fire at [endsAt] (immediately if the
  /// deadline already passed). Replaces any previously scheduled one.
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  });

  /// Cancels any pending scheduled notification.
  Future<void> cancel();
}
