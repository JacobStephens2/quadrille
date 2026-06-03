import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/auth_api.dart';
import 'data/token_store.dart';

/// The account server (auth + per-user sync) lives same-origin at `/api`.
const String accountApiBaseUrl = 'https://quadrille.app/api';

enum AuthStatus { localOnly, signedIn }

@immutable
class AuthState {
  const AuthState({required this.status, this.user});

  final AuthStatus status;
  final AuthUser? user;

  bool get isSignedIn => status == AuthStatus.signedIn;
  bool get isVerified => user?.emailVerified ?? false;
  bool get canSync => isSignedIn && isVerified;

  static const localOnly = AuthState(status: AuthStatus.localOnly);
}

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final authApiProvider =
    Provider<AuthApi>((ref) => AuthApi(baseUrl: accountApiBaseUrl));

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

String _platform() => kIsWeb ? 'web' : defaultTargetPlatform.name;

/// Owns auth state. Restores the session on launch (stored token on mobile,
/// cookie on web). Network failures resolve to local-only so the app still
/// works offline.
class AuthController extends AsyncNotifier<AuthState> {
  AuthApi get _api => ref.read(authApiProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  @override
  Future<AuthState> build() async {
    final token = await _tokens.read();
    try {
      final user = await _api.me(bearer: token);
      if (user != null) {
        return AuthState(status: AuthStatus.signedIn, user: user);
      }
    } catch (_) {
      // Offline / server down — fall back to local-only; retry on next action.
    }
    return AuthState.localOnly;
  }

  Future<void> register(String email, String password) async {
    final session =
        await _api.register(email: email, password: password, platform: _platform());
    await _adopt(session);
  }

  Future<void> login(String email, String password) async {
    final session =
        await _api.login(email: email, password: password, platform: _platform());
    await _adopt(session);
  }

  Future<void> _adopt(AuthSession session) async {
    if (session.token != null) await _tokens.write(session.token!);
    state = AsyncData(AuthState(status: AuthStatus.signedIn, user: session.user));
  }

  Future<void> logout() async {
    final token = await _tokens.read();
    try {
      await _api.logout(bearer: token);
    } catch (_) {}
    await _tokens.clear();
    state = const AsyncData(AuthState.localOnly);
  }

  /// Re-checks the session (e.g. after verifying email in another tab).
  Future<void> refresh() async {
    final token = await _tokens.read();
    final user = await _api.me(bearer: token);
    state = AsyncData(user == null
        ? AuthState.localOnly
        : AuthState(status: AuthStatus.signedIn, user: user));
  }

  Future<void> resendVerification() async {
    await _api.resendVerification(bearer: await _tokens.read());
  }
}
