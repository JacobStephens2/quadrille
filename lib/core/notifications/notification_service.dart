/// A thin, platform-abstracted notification surface for "rest complete".
///
/// The web implementation fires a browser notification at the deadline; the
/// stub (mobile/desktop for now) is a no-op — real mobile delivery via
/// `flutter_local_notifications` lands once it can be verified on a device.
library;

export 'notification_service_stub.dart'
    if (dart.library.io) 'notification_service_mobile.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';

abstract interface class NotificationService {
  /// Requests permission if needed; returns true when notifications are usable.
  Future<bool> ensurePermission();

  /// Schedules a one-shot notification to fire at [endsAt] (immediately if the
  /// deadline already passed). Replaces any previously scheduled one.
  void scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  });

  /// Cancels any pending scheduled notification.
  void cancel();
}
