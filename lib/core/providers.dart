import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database/database.dart';

/// Root provider for the local database — the single source of truth.
///
/// Everything that persists data depends on this, and tests override it with
/// an in-memory `QuadrilleDatabase.forTesting(...)`. Riverpod doubles as the
/// dependency-injection container, so there are no global singletons.
final databaseProvider = Provider<QuadrilleDatabase>((ref) {
  final db = QuadrilleDatabase();
  ref.onDispose(db.close);
  return db;
});
