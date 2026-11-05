import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../backup/backup_providers.dart';
import 'data/auth_api.dart';
import 'data/profile_store.dart';
import 'data/token_store.dart';

/// The account server (auth + per-user sync) lives same-origin at `/api`.
const String accountApiBaseUrl = 'https://quadrille.app/api';

/// Local DB profile name for a given account.
String userProfileName(String userId) => 'quadrille_user_$userId';

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

final profileStoreProvider = Provider<ProfileStore>((ref) => ProfileStore());

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(baseUrl: accountApiBaseUrl),
);

final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// A validated credential and its matching Local profile. Each publication is
/// a new ownership generation, even when the same account signs in again.
@immutable
class AuthSyncContext {
  const AuthSyncContext({
    required this.accountId,
    required this.profileName,
    required this.bearer,
    required this.generation,
  });

  final String accountId;
  final String profileName;
  final String? bearer;
  final Object generation;
}

/// Separate from UI auth state: the old account can still be rendered while a
/// transition is pending, but it is no longer eligible to submit sync work.
final authSyncContextProvider = Provider<AuthSyncContext?>((ref) {
  ref.watch(authControllerProvider);
  return ref.read(authControllerProvider.notifier)._syncContext;
});

String _platform() => kIsWeb ? 'web' : defaultTargetPlatform.name;

/// Owns auth state. Restores the session on launch (stored token on mobile,
/// cookie on web). Network failures resolve to local-only so the app still
/// works offline.
class AuthController extends AsyncNotifier<AuthState> {
  AuthApi get _api => ref.read(authApiProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);
  AuthSyncContext? _syncContext;
  Object _transition = Object();
  Future<void> _adoptionTail = Future.value();

  Object _begin({bool notify = true}) {
    _syncContext = null;
    _transition = Object();
    if (notify) ref.notifyListeners();
    return _transition;
  }

  void _check(Object transition) {
    if (!ref.mounted || !identical(transition, _transition)) {
      throw const AuthException('Account changed. Please try again.');
    }
  }

  void _publish(Object transition, AuthUser user, String? bearer) {
    _check(transition);
    final profile = userProfileName(user.id);
    if (user.emailVerified && ref.read(currentProfileProvider) == profile) {
      _syncContext = AuthSyncContext(
        accountId: user.id,
        profileName: profile,
        bearer: kIsWeb ? null : bearer,
        generation: transition,
      );
    }
  }

  // Persistent credential/profile writes cannot overtake one another. Network
  // requests stay outside this queue, so a stalled obsolete login cannot hold
  // up the next account. Every queued adoption checks its transition on entry.
  Future<void> _serializeAdoption(
    Object transition,
    Future<void> Function() action,
  ) {
    final result = _adoptionTail.then((_) {
      _check(transition);
      return action();
    });
    _adoptionTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<AuthState> build() async {
    final transition = _begin(notify: false);
    ref.onDispose(() {
      _transition = Object();
      _syncContext = null;
    });
    try {
      final token = await _tokens.read();
      _check(transition);
      final user = await _api.me(bearer: token);
      _check(transition);
      if (user != null) {
        // Reopen this account's DB (esp. on web, where we don't persist the
        // profile pointer and the launch default is the guest profile).
        final profile = userProfileName(user.id);
        await _serializeAdoption(transition, () async {
          if (ref.read(currentProfileProvider) != profile) {
            await _switchProfile(transition, profile);
          }
        });
        _publish(transition, user, token);
        return AuthState(status: AuthStatus.signedIn, user: user);
      }
    } catch (_) {
      // Offline / server down — fall back to local-only; retry on next action.
    }
    if (!ref.mounted) return AuthState.localOnly;
    if (!identical(transition, _transition)) {
      return state.value ?? AuthState.localOnly;
    }
    return AuthState.localOnly;
  }

  Future<void> register(String email, String password) async {
    final transition = _begin();
    final session = await _api.register(
      email: email,
      password: password,
      platform: _platform(),
    );
    _check(transition);
    await _serializeAdoption(transition, () => _adopt(transition, session));
  }

  Future<void> login(String email, String password) async {
    final transition = _begin();
    final session = await _api.login(
      email: email,
      password: password,
      platform: _platform(),
    );
    _check(transition);
    await _serializeAdoption(transition, () => _adopt(transition, session));
  }

  Future<void> _adopt(Object transition, AuthSession session) async {
    // Per-user DB isolation: each account uses its own local database. If we
    // were in the guest profile, carry that guest data into the account, then
    // wipe guest so it can't leak to the next user on a shared device.
    final onGuest = ref.read(currentProfileProvider) == localProfileName;
    Map<String, dynamic>? carry;
    if (onGuest) {
      final guestBackup = ref.read(backupServiceProvider);
      carry = await guestBackup.exportSyncPayload();
      _check(transition);
      await guestBackup.wipeAllData();
      _check(transition);
    }
    if (session.token != null) await _tokens.write(session.token!);
    _check(transition);
    await _switchProfile(transition, userProfileName(session.user.id));
    _check(transition);
    if (carry != null) {
      await ref.read(backupServiceProvider).mergeIntoLocal(carry);
      _check(transition);
    }
    _publish(transition, session.user, session.token);
    state = AsyncData(
      AuthState(status: AuthStatus.signedIn, user: session.user),
    );
  }

  Future<void> _switchProfile(Object transition, String name) async {
    await ref.read(profileStoreProvider).write(name);
    _check(transition);
    ref.read(currentProfileProvider.notifier).set(name);
  }

  Future<void> logout() async {
    final transition = _begin();
    final token = await _tokens.read();
    _check(transition);
    try {
      await _api.logout(bearer: token);
    } catch (_) {}
    _check(transition);
    await _serializeAdoption(transition, () async {
      await _tokens.clear();
      _check(transition);
      // The account's data stays in its own DB for the next sign-in.
      await _switchProfile(transition, localProfileName);
      _check(transition);
      state = const AsyncData(AuthState.localOnly);
    });
  }

  /// Re-checks the session (e.g. after verifying email in another tab).
  Future<void> refresh() async {
    final transition = _begin();
    final token = await _tokens.read();
    _check(transition);
    final user = await _api.me(bearer: token);
    _check(transition);
    if (user != null) _publish(transition, user, token);
    state = AsyncData(
      user == null
          ? AuthState.localOnly
          : AuthState(status: AuthStatus.signedIn, user: user),
    );
  }

  Future<void> resendVerification() async {
    await _api.resendVerification(bearer: await _tokens.read());
  }
}
