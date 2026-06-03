import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database/database.dart';

/// Default (guest / not-signed-in) local database name.
const String localProfileName = 'quadrille_local';

/// The local database namespace currently in use. Each account gets its own
/// (`quadrille_user_<id>`) so two accounts on one shared device never see each
/// other's data; guest use lives in [localProfileName]. Changing this reopens
/// the database (and everything that depends on it).
class ProfileController extends Notifier<String> {
  @override
  String build() => localProfileName;

  void set(String profileName) => state = profileName;
}

final currentProfileProvider =
    NotifierProvider<ProfileController, String>(ProfileController.new);

/// Root provider for the local database — the single source of truth for the
/// active profile. Everything that persists data depends on this; tests
/// override it with an in-memory `QuadrilleDatabase.forTesting(...)`.
final databaseProvider = Provider<QuadrilleDatabase>((ref) {
  final profile = ref.watch(currentProfileProvider);
  final db = QuadrilleDatabase(profile);
  ref.onDispose(db.close);
  return db;
});
