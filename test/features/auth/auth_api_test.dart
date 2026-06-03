import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';

void main() {
  const base = 'https://quadrille.app/api';

  test('register posts credentials and returns user + token', () async {
    late http.Request captured;
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'token': 'sess-token',
            'user': {'id': 'u1', 'email': 'a@b.com', 'emailVerified': false},
          }),
          200,
        );
      }),
    );

    final session = await api.register(email: 'a@b.com', password: 'hunter2pass');
    expect(captured.url.toString(), '$base/auth/register');
    expect(jsonDecode(captured.body)['email'], 'a@b.com');
    expect(session.token, 'sess-token');
    expect(session.user.email, 'a@b.com');
    expect(session.user.emailVerified, isFalse);
  });

  test('login error surfaces the server detail message', () async {
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async =>
          http.Response(jsonEncode({'detail': 'Invalid email or password'}), 401)),
    );
    expect(
      () => api.login(email: 'a@b.com', password: 'nope'),
      throwsA(isA<AuthException>().having((e) => e.message, 'message',
          'Invalid email or password')),
    );
  });

  test('me returns null on 401 (signed out)', () async {
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async => http.Response('', 401)),
    );
    expect(await api.me(), isNull);
  });

  test('me sends the bearer token when provided', () async {
    late http.Request captured;
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'user': {'id': 'u1', 'email': 'a@b.com', 'emailVerified': true}}),
          200,
        );
      }),
    );
    final user = await api.me(bearer: 'tok');
    expect(captured.headers['Authorization'], 'Bearer tok');
    expect(user!.emailVerified, isTrue);
  });

  test('putSync sends payload and returns revision', () async {
    late http.Request captured;
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'revision': 7}), 200);
      }),
    );
    final rev = await api.putSync({'format': 'quadrille.backup', 'version': 2}, bearer: 'tok');
    expect(captured.method, 'PUT');
    expect(captured.url.toString(), '$base/sync');
    expect(rev, 7);
  });

  test('getSync reports an empty cloud', () async {
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async =>
          http.Response(jsonEncode({'exists': false, 'revision': 0, 'payload': null}), 200)),
    );
    final remote = await api.getSync(bearer: 'tok');
    expect(remote.exists, isFalse);
  });

  test('network failure becomes a friendly AuthException', () async {
    final api = AuthApi(
      baseUrl: base,
      client: MockClient((req) async => throw Exception('boom')),
    );
    expect(
      () => api.login(email: 'a@b.com', password: 'x'),
      throwsA(isA<AuthException>()),
    );
  });
}
