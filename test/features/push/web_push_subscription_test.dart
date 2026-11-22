import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quadrille/features/push/web_push_client.dart';

const _api = 'https://quadrille.app/api';
const _browserEndpoint = 'https://fcm.googleapis.com/fcm/send/this-browser';
const _otherDevice = 'https://updates.push.services.mozilla.com/wpush/v2/phone';

class _Browser implements BrowserPushPort {
  _Browser(this.subscription);

  final BrowserPushSubscription subscription;
  @override
  bool notificationsGranted = true;
  BrowserPushSubscription? current;
  int subscribes = 0;

  @override
  Future<BrowserPushSubscription?> currentSubscription() async => current;

  @override
  Future<BrowserPushSubscription?> subscribe(
    Uint8List applicationServerKey,
  ) async {
    subscribes++;
    current = subscription;
    return subscription;
  }
}

void main() {
  test(
    'removeSubscription deletes this browser endpoint and the next schedule registers it',
    () async {
      final browser = _Browser(
        const BrowserPushSubscription(
          endpoint: _browserEndpoint,
          p256dh: 'browser-p256dh',
          auth: 'browser-auth',
        ),
      );
      final requests = <http.Request>[];
      final client = WebPushSubscriptionClient(
        browser: browser,
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/push/key') {
            final key = base64Url.encode(Uint8List.fromList([1, 2, 3, 4]));
            return http.Response(jsonEncode({'key': key}), 200);
          }
          return http.Response('{"ok":true}', 200);
        }),
      );

      Future<void> schedule() => client.scheduleRest(
        endpoint: _api,
        endsAt: DateTime.utc(2026, 11, 22, 12),
        title: 'Rest complete',
        body: 'Next: Bench',
      );

      await schedule();
      await schedule();

      expect(browser.subscribes, 1);
      expect(
        requests.where((request) => request.method == 'PUT').map((request) {
          return jsonDecode(request.body)['endpoint'];
        }),
        [_browserEndpoint],
      );
      expect(
        requests.map((request) => request.body).join(),
        isNot(contains(_otherDevice)),
      );

      requests.clear();
      await client.removeSubscription(endpoint: _api);

      expect(browser.subscribes, 1);
      expect(requests.map((request) => request.method), ['DELETE']);
      expect(requests.single.url.path, '/api/push/subscription');
      expect(jsonDecode(requests.single.body), {'endpoint': _browserEndpoint});

      requests.clear();
      await schedule();

      expect(browser.subscribes, 2);
      final puts = requests.where((request) => request.method == 'PUT');
      expect(puts, hasLength(1));
      expect(jsonDecode(puts.single.body)['endpoint'], _browserEndpoint);
    },
  );

  test(
    'removeSubscription deletes the live subscription when this page has not registered it',
    () async {
      final browser = _Browser(
        const BrowserPushSubscription(
          endpoint: _browserEndpoint,
          p256dh: 'browser-p256dh',
          auth: 'browser-auth',
        ),
      );
      browser.current = browser.subscription;
      final requests = <http.Request>[];
      final client = WebPushSubscriptionClient(
        browser: browser,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{"ok":true}', 200);
        }),
      );

      await client.removeSubscription(endpoint: _api);

      expect(browser.subscribes, 0);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'DELETE');
      expect(jsonDecode(requests.single.body), {'endpoint': _browserEndpoint});
    },
  );

  test(
    'in-flight subscribe PUT cannot restore subscribed state after remove',
    () async {
      final browser = _Browser(
        const BrowserPushSubscription(
          endpoint: _browserEndpoint,
          p256dh: 'browser-p256dh',
          auth: 'browser-auth',
        ),
      );
      final putEntered = Completer<void>();
      final releasePut = Completer<http.Response>();
      final methods = <String>[];
      final client = WebPushSubscriptionClient(
        browser: browser,
        httpClient: MockClient((request) async {
          methods.add(request.method);
          if (request.url.path == '/api/push/key') {
            return http.Response(
              jsonEncode({
                'key': base64Url.encode(Uint8List.fromList([1, 2, 3, 4])),
              }),
              200,
            );
          }
          if (request.method == 'PUT') {
            if (!putEntered.isCompleted) putEntered.complete();
            return releasePut.future;
          }
          return http.Response('{"ok":true}', 200);
        }),
      );

      final pending = client.scheduleRest(
        endpoint: _api,
        endsAt: DateTime.utc(2026, 11, 22, 12),
        title: 'Rest complete',
        body: 'Next: Bench',
      );
      await putEntered.future;
      await client.removeSubscription(endpoint: _api);
      releasePut.complete(http.Response('{"ok":true}', 200));
      await pending;

      methods.clear();
      await client.scheduleRest(
        endpoint: _api,
        endsAt: DateTime.utc(2026, 11, 22, 12, 1),
        title: 'Rest complete',
        body: 'Next: Row',
      );
      expect(methods.where((method) => method == 'PUT'), hasLength(1));
    },
  );
}
