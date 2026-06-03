import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists which local database profile is active, so the app reopens the
/// right one on launch (before the network confirms the session). The profile
/// name isn't sensitive, so this is stored on every platform (incl. web).
class ProfileStore {
  static const _key = 'quadrille_active_profile';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<String?> read() => _storage.read(key: _key);
  Future<void> write(String profileName) =>
      _storage.write(key: _key, value: profileName);
}
