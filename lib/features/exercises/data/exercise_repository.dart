import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/ids.dart';

/// Persistence for the canonical exercise catalog.
///
/// Returns Drift's generated [Exercise] row type directly; the UI/view-models
/// consume it through this seam, so the storage detail never leaks into
/// widgets and can be swapped (e.g. for sync) without touching them.
class ExerciseRepository {
  ExerciseRepository(this._db);

  final QuadrilleDatabase _db;

  /// All non-archived exercises, alphabetical, as a reactive stream.
  Stream<List<Exercise>> watchAll() {
    return (_db.select(_db.exercises)
          ..where((e) => e.archived.equals(false))
          ..orderBy([(e) => OrderingTerm(expression: e.name)]))
        .watch();
  }

  Future<Exercise?> getById(String id) {
    return (_db.select(_db.exercises)..where((e) => e.id.equals(id)))
        .getSingleOrNull();
  }

  /// Creates a new exercise and returns its generated id.
  Future<String> create({
    required String name,
    ExerciseCategory category = ExerciseCategory.other,
    int defaultRestSeconds = 120,
    LoadKind loadKind = LoadKind.externalWeight,
    bool isUnilateral = false,
    String? notes,
  }) async {
    final id = newId();
    final now = DateTime.now();
    await _db.into(_db.exercises).insert(
          ExercisesCompanion.insert(
            id: id,
            name: name,
            category: Value(category),
            defaultRestSeconds: Value(defaultRestSeconds),
            loadKind: Value(loadKind),
            isUnilateral: Value(isUnilateral),
            notes: Value(notes),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> update(
    String id, {
    String? name,
    ExerciseCategory? category,
    int? defaultRestSeconds,
    LoadKind? loadKind,
    bool? isUnilateral,
    String? notes,
  }) async {
    await (_db.update(_db.exercises)..where((e) => e.id.equals(id))).write(
      ExercisesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        category: category == null ? const Value.absent() : Value(category),
        defaultRestSeconds: defaultRestSeconds == null
            ? const Value.absent()
            : Value(defaultRestSeconds),
        loadKind: loadKind == null ? const Value.absent() : Value(loadKind),
        isUnilateral:
            isUnilateral == null ? const Value.absent() : Value(isUnilateral),
        notes: notes == null ? const Value.absent() : Value(notes),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Soft-deletes by archiving, so templates/history referencing it stay valid.
  Future<void> archive(String id) async {
    await (_db.update(_db.exercises)..where((e) => e.id.equals(id))).write(
      ExercisesCompanion(
        archived: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
