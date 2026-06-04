import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists which local database profile is active, so the app reopens the
/// right one on launch (before the network confirms the session).
///
/// Mobile/desktop only — on web the active profile is re-derived from the
/// restored session (`/auth/me` over the cookie), so we don't touch
/// secure storage there.
class ProfileStore {
  static const _key = 'quadrille_active_profile';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<String?> read() async {
    if (kIsWeb) return null;
    return _storage.read(key: _key);
  }

  Future<void> write(String profileName) async {
    if (kIsWeb) return;
    await _storage.write(key: _key, value: profileName);
  }
}
