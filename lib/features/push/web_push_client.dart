import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'web_push_service.dart';

/// One browser Push subscription the web adapter read or created.
class BrowserPushSubscription {
  const BrowserPushSubscription({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  });

  final String endpoint;
  final String? p256dh;
  final String? auth;
}

/// Browser Push API operations. The web adapter is the only production one.
abstract class BrowserPushPort {
  bool get notificationsGranted;

  /// The subscription already held by this browser's service worker, if any.
  Future<BrowserPushSubscription?> currentSubscription();

  /// Registers the service worker if needed and subscribes this browser.
  Future<BrowserPushSubscription?> subscribe(Uint8List applicationServerKey);
}

/// Registers, schedules, and removes Web Push for one browser.
///
/// Subscribed state means the signed-in account has this browser's
/// subscription stored. Sign-out clears that state and deletes only that
/// stored endpoint, so the next account's [scheduleRest] registers the same
/// browser again.
class WebPushSubscriptionClient implements WebPushService {
  WebPushSubscriptionClient({
    required this._browser,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final BrowserPushPort _browser;
  final http.Client _http;
  bool _subscribed = false;
  String? _storedEndpoint;

  static const _json = {'Content-Type': 'application/json'};

  Uri _u(String endpoint, String path) =>
      Uri.parse('${endpoint.replaceAll(RegExp(r'/+$'), '')}$path');

  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
    bool Function()? stillOwned,
  }) async {
    try {
      if (stillOwned != null && !stillOwned()) return;
      await _ensureSubscribed(endpoint, stillOwned: stillOwned);
      if (!_subscribed) return;
      if (stillOwned != null && !stillOwned()) return;
      await _http.post(
        _u(endpoint, '/push/schedule'),
        headers: _json,
        body: jsonEncode({
          'timestamp': endsAt.millisecondsSinceEpoch,
          'title': title,
          'body': body,
        }),
      );
    } catch (_) {
      /* best-effort; in-page timer / SW trigger still cover it */
    }
  }

  @override
  Future<void> cancel({required String endpoint}) async {
    try {
      await _http.post(_u(endpoint, '/push/cancel'));
    } catch (_) {}
  }

  @override
  Future<void> removeSubscription({required String endpoint}) async {
    _subscribed = false;
    final endpoints = <String>{};
    final remembered = _storedEndpoint;
    _storedEndpoint = null;
    if (remembered != null) endpoints.add(remembered);
    try {
      final current = await _browser.currentSubscription();
      if (current != null) endpoints.add(current.endpoint);
    } catch (_) {}
    for (final pushEndpoint in endpoints) {
      try {
        await _delete(endpoint, pushEndpoint);
      } catch (_) {}
    }
  }

  Future<void> _ensureSubscribed(
    String endpoint, {
    bool Function()? stillOwned,
  }) async {
    bool isOwned() => stillOwned?.call() ?? true;
    if (_subscribed || !isOwned()) return;
    if (!_browser.notificationsGranted) return;

    final keyResp = await _http.get(_u(endpoint, '/push/key'));
    if (!isOwned() || keyResp.statusCode != 200) return;
    final appKey = _decodeBase64Url(
      (jsonDecode(keyResp.body) as Map<String, dynamic>)['key'] as String,
    );

    final sub = await _browser.subscribe(appKey);
    if (!isOwned() || sub == null) return;

    final p256dh = sub.p256dh;
    final auth = sub.auth;
    if (p256dh == null || auth == null) return;

    final resp = await _http.put(
      _u(endpoint, '/push/subscription'),
      headers: _json,
      body: jsonEncode({
        'endpoint': sub.endpoint,
        'keys': {'p256dh': p256dh, 'auth': auth},
      }),
    );
    _subscribed = resp.statusCode == 200;
    if (_subscribed) _storedEndpoint = sub.endpoint;
  }

  Future<void> _delete(String endpoint, String pushEndpoint) async {
    final request = http.Request('DELETE', _u(endpoint, '/push/subscription'))
      ..headers.addAll(_json)
      ..body = jsonEncode({'endpoint': pushEndpoint});
    final streamed = await _http.send(request);
    await streamed.stream.drain<void>();
  }

  Uint8List _decodeBase64Url(String value) {
    final normalized = base64Url.normalize(value);
    return base64Url.decode(normalized);
  }
}
