import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_service.dart';

NotificationService createNotificationService() => _WebNotificationService();

/// Browser-notification implementation. Schedules with a Dart [Timer] that
/// fires while the tab is open or backgrounded; full closed-tab delivery would
/// need a service worker (a later increment).
class _WebNotificationService implements NotificationService {
  Timer? _timer;

  @override
  Future<bool> ensurePermission() async {
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
    final delay = endsAt.difference(DateTime.now());
    if (delay.isNegative || delay == Duration.zero) {
      _show(title, body);
      return;
    }
    _timer = Timer(delay, () => _show(title, body));
  }

  void _show(String title, String body) {
    if (web.Notification.permission != 'granted') return;
    web.Notification(title, web.NotificationOptions(body: body));
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
