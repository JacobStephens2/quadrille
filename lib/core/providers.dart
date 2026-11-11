import 'package:flutter/foundation.dart';
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

final currentProfileProvider = NotifierProvider<ProfileController, String>(
  ProfileController.new,
);

/// Root provider for the local database — the single source of truth for the
/// active profile. Everything that persists data depends on this; tests
/// override it with an in-memory `QuadrilleDatabase.forTesting(...)`.
final databaseProvider = Provider<QuadrilleDatabase>((ref) {
  final profile = ref.watch(currentProfileProvider);
  final db = QuadrilleDatabase(profile);
  ref.onDispose(db.close);
  return db;
});

/// One runtime ownership period for a Local profile and its exact database.
/// Retirement is permanent and synchronous; accepted work retains its captured
/// destination, while each workflow decides whether it may start another stage.
class LocalProfileGeneration implements Listenable {
  LocalProfileGeneration._(this._ref, this.profileName, this.database);

  final Ref _ref;
  final String profileName;
  final QuadrilleDatabase database;
  final _current = ValueNotifier(true);

  bool get isCurrent =>
      _current.value &&
      _ref.mounted &&
      _ref.read(currentProfileProvider) == profileName &&
      identical(_ref.read(databaseProvider), database);

  void _retire() {
    if (!_current.value) return;
    // Listeners must observe an obsolete generation, without reading a Ref
    // from inside the provider disposal lifecycle.
    _current.value = false;
  }

  @override
  void addListener(VoidCallback listener) => _current.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _current.removeListener(listener);
}

/// Retained independently of feature and screen subscriptions.
final localProfileGenerationProvider = Provider<LocalProfileGeneration>((ref) {
  final generation = LocalProfileGeneration._(
    ref,
    ref.watch(currentProfileProvider),
    ref.watch(databaseProvider),
  );
  // Watching alone can miss A-to-B-to-A before a lazy consumer rebuilds.
  ref.listen(currentProfileProvider, (_, _) => generation._retire());
  ref.listen(databaseProvider, (_, _) => generation._retire());
  ref.onDispose(generation._retire);
  return generation;
});
