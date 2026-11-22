import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'web_push_client.dart';
import 'web_push_service.dart';

WebPushService createWebPushService() =>
    WebPushSubscriptionClient(browser: _WebBrowserPush());

/// PushManager behind the narrow Quadrille notification service worker.
class _WebBrowserPush implements BrowserPushPort {
  static const _scope = '/quadrille-notif/';

  @override
  bool get notificationsGranted => web.Notification.permission == 'granted';

  @override
  Future<BrowserPushSubscription?> currentSubscription() async {
    final reg = await web.window.navigator.serviceWorker
        .getRegistration(_scope)
        .toDart;
    if (reg == null) return null;
    final sub = await reg.pushManager.getSubscription().toDart;
    return sub == null ? null : _from(sub);
  }

  @override
  Future<BrowserPushSubscription?> subscribe(
    Uint8List applicationServerKey,
  ) async {
    final reg = await web.window.navigator.serviceWorker
        .register(
          'quadrille_sw.js'.toJS,
          web.RegistrationOptions(scope: _scope),
        )
        .toDart;
    final sub = await reg.pushManager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            userVisibleOnly: true,
            applicationServerKey: applicationServerKey.toJS,
          ),
        )
        .toDart;
    return _from(sub);
  }

  BrowserPushSubscription _from(web.PushSubscription sub) {
    return BrowserPushSubscription(
      endpoint: sub.endpoint,
      p256dh: _encodeKey(sub.getKey('p256dh')),
      auth: _encodeKey(sub.getKey('auth')),
    );
  }

  String? _encodeKey(JSArrayBuffer? buffer) {
    if (buffer == null) return null;
    final bytes = buffer.toDart.asUint8List();
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
