import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/ids.dart';
import '../domain/template_exercise_draft.dart';

/// Persistence for workout templates and their exercise rows.
class TemplateRepository {
  TemplateRepository(this._db);

  final QuadrilleDatabase _db;

  /// Non-archived templates ordered by their manual sort order, then name.
  Stream<List<WorkoutTemplate>> watchTemplates() {
    return (_db.select(_db.workoutTemplates)
          ..where((t) => t.archived.equals(false) & t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  Stream<WorkoutTemplate?> watchTemplate(String id) {
    return (_db.select(_db.workoutTemplates)..where((t) => t.id.equals(id)))
        .watchSingleOrNull();
  }

  /// Exercise rows for a template, ordered as they appear on the sheet.
  /// Excludes soft-deleted (tombstoned) rows.
  Stream<List<TemplateExercise>> watchExercises(String templateId) {
    return (_db.select(_db.templateExercises)
          ..where((e) => e.templateId.equals(templateId) & e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm(expression: e.sortIndex)]))
        .watch();
  }

  Future<String> createTemplate({
    required String name,
    String? dayLabel,
    int sortOrder = 0,
    String? notes,
  }) async {
    final id = newId();
    final now = DateTime.now();
    await _db.into(_db.workoutTemplates).insert(
          WorkoutTemplatesCompanion.insert(
            id: id,
            name: name,
            dayLabel: Value(dayLabel),
            sortOrder: Value(sortOrder),
            notes: Value(notes),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> updateTemplate(
    String id, {
    String? name,
    String? dayLabel,
    int? sortOrder,
    String? notes,
  }) async {
    await (_db.update(_db.workoutTemplates)..where((t) => t.id.equals(id)))
        .write(
      WorkoutTemplatesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        dayLabel: dayLabel == null ? const Value.absent() : Value(dayLabel),
        sortOrder: sortOrder == null ? const Value.absent() : Value(sortOrder),
        notes: notes == null ? const Value.absent() : Value(notes),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> archiveTemplate(String id) async {
    await (_db.update(_db.workoutTemplates)..where((t) => t.id.equals(id)))
        .write(
      WorkoutTemplatesCompanion(
        archived: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Deep-copies a template and all its exercise rows under a new name.
  Future<String> duplicateTemplate(String id, {required String newName}) async {
    return _db.transaction(() async {
      final source = await (_db.select(_db.workoutTemplates)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      final newTemplateId = await createTemplate(
        name: newName,
        dayLabel: source.dayLabel,
        sortOrder: source.sortOrder + 1,
        notes: source.notes,
      );
      final rows = await (_db.select(_db.templateExercises)
            ..where((e) => e.templateId.equals(id) & e.deletedAt.isNull()))
          .get();
      final now = DateTime.now();
      await _db.batch((batch) {
        for (final row in rows) {
          batch.insert(
            _db.templateExercises,
            row.toCompanion(false).copyWith(
                  id: Value(newId()),
                  templateId: Value(newTemplateId),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
          );
        }
      });
      return newTemplateId;
    });
  }

  Future<String> addExercise(String templateId, TemplateExerciseDraft draft) async {
    final id = newId();
    final now = DateTime.now();
    await _db.into(_db.templateExercises).insert(
          _companionFor(id, templateId, draft, now, isNew: true),
        );
    return id;
  }

  Future<void> updateExercise(
    String id,
    String templateId,
    TemplateExerciseDraft draft,
  ) async {
    await (_db.update(_db.templateExercises)..where((e) => e.id.equals(id)))
        .write(_companionFor(id, templateId, draft, DateTime.now()));
  }

  /// Soft-deletes a template row (tombstone) so the deletion propagates on sync.
  Future<void> deleteExercise(String id) async {
    final now = DateTime.now();
    await (_db.update(_db.templateExercises)..where((e) => e.id.equals(id)))
        .write(
      TemplateExercisesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  TemplateExercisesCompanion _companionFor(
    String id,
    String templateId,
    TemplateExerciseDraft d,
    DateTime now, {
    bool isNew = false,
  }) {
    return TemplateExercisesCompanion(
      id: Value(id),
      templateId: Value(templateId),
      exerciseId: Value(d.exerciseId),
      displayName: Value(d.displayName),
      orderLabel: Value(d.orderLabel),
      sortIndex: Value(d.sortIndex),
      supersetGroup: Value(d.supersetGroup),
      targetSets: Value(d.targetSets),
      repMin: Value(d.repTarget.repMin),
      repMax: Value(d.repTarget.repMax),
      durationMinSeconds: Value(d.repTarget.durationMin?.inSeconds),
      durationMaxSeconds: Value(d.repTarget.durationMax?.inSeconds),
      restSeconds: Value(d.restSeconds),
      notes: Value(d.notes),
      isUnilateral: Value(d.isUnilateral),
      loadKind: Value(d.loadKind),
      createdAt: isNew ? Value(now) : const Value.absent(),
      updatedAt: Value(now),
    );
  }
}
