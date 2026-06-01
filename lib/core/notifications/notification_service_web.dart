import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_service.dart';

NotificationService createNotificationService() => _WebNotificationService();

/// Browser notifications for "rest complete".
///
/// Schedules through a service worker using a TimestampTrigger where the
/// browser supports it (fires even after the tab is closed), and falls back to
/// an in-page [Timer] otherwise (fires while the tab is open or backgrounded).
/// Both paths share a tag so they never double-notify.
class _WebNotificationService implements NotificationService {
  Timer? _timer;
  web.ServiceWorkerRegistration? _registration;
  static const String _tag = 'quadrille-rest';

  Future<void> _ensureServiceWorker() async {
    if (_registration != null) return;
    try {
      final container = web.window.navigator.serviceWorker;
      _registration = await container
          .register(
            'quadrille_sw.js'.toJS,
            web.RegistrationOptions(scope: '/quadrille-notif/'),
          )
          .toDart;
    } catch (_) {
      // Service workers unavailable (e.g. insecure context) — fall back to the
      // in-page timer only.
    }
  }

  @override
  Future<bool> ensurePermission() async {
    await _ensureServiceWorker();
    final current = web.Notification.permission;
    if (current == 'granted') return true;
    if (current == 'denied') return false;
    final result = await web.Notification.requestPermission().toDart;
    return result.toDart == 'granted';
  }

  @override
  void scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
  }) {
    cancel();

    // Ask the SW to schedule a triggered notification (survives a closed tab
    // where supported); harmless no-op otherwise.
    _registration?.active?.postMessage(
      {
        'type': 'scheduleRest',
        'title': title,
        'body': body,
        'timestamp': endsAt.millisecondsSinceEpoch,
      }.jsify(),
    );

    // In-page fallback for the common open/backgrounded case.
    final delay = endsAt.difference(DateTime.now());
    if (delay <= Duration.zero) {
      _show(title, body);
      return;
    }
    _timer = Timer(delay, () => _show(title, body));
  }

  void _show(String title, String body) {
    if (web.Notification.permission != 'granted') return;
    web.Notification(title, web.NotificationOptions(body: body, tag: _tag));
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _registration?.active?.postMessage({'type': 'cancelRest'}.jsify());
  }
}
