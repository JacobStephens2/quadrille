library;

export 'web_push_service_stub.dart'
    if (dart.library.js_interop) 'web_push_service_web.dart';

/// Schedules a server-sent Web Push at the rest deadline so the alert fires
/// even when the browser tab is fully closed. Web-only; a no-op elsewhere.
///
/// Authenticates with the account session cookie (same-origin `/api`), so it
/// works once the user is signed in + verified.
abstract interface class WebPushService {
  /// Ensures a push subscription exists, then schedules the rest-complete push.
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
  });

  /// Cancels a pending scheduled push.
  Future<void> cancel({required String endpoint});
}
