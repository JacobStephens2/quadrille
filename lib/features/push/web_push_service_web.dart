import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'web_push_service.dart';

WebPushService createWebPushService() => _WebPushService();

/// Real Web Push: subscribes via the service worker's PushManager (using the
/// server's VAPID key), registers the subscription, and asks the server to
/// schedule the rest-complete push at the deadline.
class _WebPushService implements WebPushService {
  bool _subscribed = false;

  Uri _u(String endpoint, String path) =>
      Uri.parse('${endpoint.replaceAll(RegExp(r'/+$'), '')}$path');

  // Same-origin requests carry the session cookie automatically; no header.
  static const _json = {'Content-Type': 'application/json'};

  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {
    try {
      await _ensureSubscribed(endpoint);
      if (!_subscribed) return;
      await http.post(
        _u(endpoint, '/push/schedule'),
        headers: _json,
        body: jsonEncode({
          'timestamp': endsAt.millisecondsSinceEpoch,
          'title': title,
          'body': body,
        }),
      );
    } catch (_) {/* best-effort; in-page timer / SW trigger still cover it */}
  }

  @override
  Future<void> cancel({required String endpoint}) async {
    try {
      await http.post(_u(endpoint, '/push/cancel'));
    } catch (_) {}
  }

  Future<void> _ensureSubscribed(String endpoint) async {
    if (_subscribed) return;
    if (web.Notification.permission != 'granted') return;

    final keyResp = await http.get(_u(endpoint, '/push/key'));
    if (keyResp.statusCode != 200) return;
    final appKey =
        _decodeBase64Url(jsonDecode(keyResp.body)['key'] as String);

    final reg = await web.window.navigator.serviceWorker
        .register(
          'quadrille_sw.js'.toJS,
          web.RegistrationOptions(scope: '/quadrille-notif/'),
        )
        .toDart;

    final sub = await reg.pushManager
        .subscribe(web.PushSubscriptionOptionsInit(
          userVisibleOnly: true,
          applicationServerKey: appKey.toJS,
        ))
        .toDart;

    final p256dh = _encodeKey(sub.getKey('p256dh'));
    final auth = _encodeKey(sub.getKey('auth'));
    if (p256dh == null || auth == null) return;

    final resp = await http.put(
      _u(endpoint, '/push/subscription'),
      headers: _json,
      body: jsonEncode({
        'endpoint': sub.endpoint,
        'keys': {'p256dh': p256dh, 'auth': auth},
      }),
    );
    _subscribed = resp.statusCode == 200;
  }

  Uint8List _decodeBase64Url(String value) {
    final normalized = base64Url.normalize(value);
    return base64Url.decode(normalized);
  }

  String? _encodeKey(JSArrayBuffer? buffer) {
    if (buffer == null) return null;
    final bytes = buffer.toDart.asUint8List();
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
