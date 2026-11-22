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
  ///
  /// [stillOwned] is checked before subscription work and immediately before
  /// submitting `/push/schedule`. When it returns false, scheduling is skipped
  /// so a retired or superseded command cannot publish a push under the wrong
  /// account or after dismissal.
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
    bool Function()? stillOwned,
  });

  /// Cancels a pending scheduled push.
  Future<void> cancel({required String endpoint});

  /// Removes this browser's stored subscription for the signed-in account
  /// and clears local subscribed state so the next account registers it.
  /// Other devices of that account stay subscribed. [endpoint] is the account
  /// API base, same as [cancel].
  Future<void> removeSubscription({required String endpoint});
}
