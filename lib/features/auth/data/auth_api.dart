import 'dart:convert';

import 'package:http/http.dart' as http;

/// A signed-in user as the server reports it.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.emailVerified,
  });

  final String id;
  final String email;
  final bool emailVerified;

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as String,
        email: json['email'] as String,
        emailVerified: json['emailVerified'] == true,
      );
}

/// Result of register/login: the user plus (mobile) the opaque session token.
/// On web the session is an httpOnly cookie, so [token] may be unused.
class AuthSession {
  const AuthSession({required this.user, this.token});
  final AuthUser user;
  final String? token;
}

class RemoteSyncState {
  const RemoteSyncState({required this.exists, required this.revision, this.payload});
  final bool exists;
  final int revision;
  final Map<String, dynamic>? payload;
}

class AuthException implements Exception {
  const AuthException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// HTTP client for the account server (auth + per-user sync) at `/api`.
///
/// Mobile authenticates with a Bearer token; web relies on the same-origin
/// session cookie (sent automatically), so [bearer] is null there.
class AuthApi {
  AuthApi({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Uri _u(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> _headers(String? bearer) => {
        'Content-Type': 'application/json',
        if (bearer != null) 'Authorization': 'Bearer $bearer',
      };

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } catch (_) {
      throw const AuthException('Could not reach the server.');
    }
  }

  Never _fail(http.Response r) {
    var message = 'Something went wrong.';
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['detail'] != null) {
        message = body['detail'].toString();
      }
    } catch (_) {}
    throw AuthException(message, statusCode: r.statusCode);
  }

  AuthSession _session(http.Response r) {
    if (r.statusCode != 200) _fail(r);
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    return AuthSession(
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      token: json['token'] as String?,
    );
  }

  Future<AuthSession> register({
    required String email,
    required String password,
    String? platform,
  }) async {
    final r = await _send(() => _client.post(
          _u('/auth/register'),
          headers: _headers(null),
          body: jsonEncode({'email': email, 'password': password, 'platform': platform}),
        ));
    return _session(r);
  }

  Future<AuthSession> login({
    required String email,
    required String password,
    String? platform,
  }) async {
    final r = await _send(() => _client.post(
          _u('/auth/login'),
          headers: _headers(null),
          body: jsonEncode({'email': email, 'password': password, 'platform': platform}),
        ));
    return _session(r);
  }

  /// Returns the current user, or null if the session is invalid/absent.
  Future<AuthUser?> me({String? bearer}) async {
    final r = await _send(() => _client.get(_u('/auth/me'), headers: _headers(bearer)));
    if (r.statusCode == 401) return null;
    if (r.statusCode != 200) _fail(r);
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    return AuthUser.fromJson(json['user'] as Map<String, dynamic>);
  }

  Future<void> logout({String? bearer}) async {
    await _send(() => _client.post(_u('/auth/logout'), headers: _headers(bearer)));
  }

  Future<void> resendVerification({String? bearer}) async {
    final r = await _send(() =>
        _client.post(_u('/auth/email/resend-verification'), headers: _headers(bearer)));
    if (r.statusCode != 200) _fail(r);
  }

  Future<void> verifyEmail(String token) async {
    final r = await _send(() => _client.post(
          _u('/auth/email/verify'),
          headers: _headers(null),
          body: jsonEncode({'token': token}),
        ));
    if (r.statusCode != 200) _fail(r);
  }

  Future<void> forgotPassword(String email) async {
    await _send(() => _client.post(
          _u('/auth/password/forgot'),
          headers: _headers(null),
          body: jsonEncode({'email': email}),
        ));
  }

  Future<void> resetPassword(String token, String password) async {
    final r = await _send(() => _client.post(
          _u('/auth/password/reset'),
          headers: _headers(null),
          body: jsonEncode({'token': token, 'password': password}),
        ));
    if (r.statusCode != 200) _fail(r);
  }

  // ---- per-user sync ----

  Future<RemoteSyncState> getSync({String? bearer}) async {
    final r = await _send(() => _client.get(_u('/sync'), headers: _headers(bearer)));
    if (r.statusCode != 200) _fail(r);
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    final exists = json['exists'] == true && json['payload'] != null;
    return RemoteSyncState(
      exists: exists,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      payload: exists ? json['payload'] as Map<String, dynamic> : null,
    );
  }

  /// Pushes a sync payload; the server merges and returns the new revision.
  Future<int> putSync(Map<String, dynamic> payload, {String? bearer}) async {
    final r = await _send(() => _client.put(
          _u('/sync'),
          headers: _headers(bearer),
          body: jsonEncode({'payload': payload}),
        ));
    if (r.statusCode != 200) _fail(r);
    return ((jsonDecode(r.body) as Map<String, dynamic>)['revision'] as num).toInt();
  }
}
