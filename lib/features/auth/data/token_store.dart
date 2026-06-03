import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the opaque session token on mobile/desktop (Keychain/Keystore via
/// flutter_secure_storage). On web the session is an httpOnly cookie, so there
/// is deliberately nothing to store in JS-reachable storage.
class TokenStore {
  static const _key = 'quadrille_session_token';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<String?> read() async {
    if (kIsWeb) return null;
    return _storage.read(key: _key);
  }

  Future<void> write(String token) async {
    if (kIsWeb) return;
    await _storage.write(key: _key, value: token);
  }

  Future<void> clear() async {
    if (kIsWeb) return;
    await _storage.delete(key: _key);
  }
}
