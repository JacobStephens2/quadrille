import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/ids.dart';
import '../domain/equipment_busy_history.dart';

/// Equipment observations within one Local profile. Like Exercise history,
/// reports match an exercise's display name case-insensitively, including
/// session exercises with no catalog entry.
class EquipmentBusyRepository {
  EquipmentBusyRepository(this._db);

  final QuadrilleDatabase _db;

  Future<String> recordBusy(String exerciseName, {required DateTime at}) async {
    final name = exerciseName.trim();
    if (name.isEmpty) throw ArgumentError.value(exerciseName, 'exerciseName');
    final id = newId();
    final now = DateTime.now();
    await _db
        .into(_db.equipmentBusyReports)
        .insert(
          EquipmentBusyReportsCompanion.insert(
            id: id,
            exerciseName: name,
            reportedAt: at,
            utcOffsetMinutes: at.timeZoneOffset.inMinutes,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Stream<EquipmentBusyHistory> watchHistory(String exerciseName) {
    return (_db.select(_db.equipmentBusyReports)
          ..where(
            (r) =>
                r.exerciseName.lower().equals(
                  exerciseName.trim().toLowerCase(),
                ) &
                r.deletedAt.isNull(),
          )
          ..orderBy([
            (r) => OrderingTerm.desc(r.reportedAt),
            (r) => OrderingTerm(expression: r.id),
          ]))
        .watch()
        .map(EquipmentBusyHistory.new);
  }

  /// Undo uses a tombstone so the correction also reaches other devices.
  Future<void> undo(String id) async {
    await _db.transaction(() async {
      final report = await (_db.select(
        _db.equipmentBusyReports,
      )..where((r) => r.id.equals(id))).getSingleOrNull();
      if (report == null || report.deletedAt != null) return;
      // SQLite stores whole seconds. An immediate undo must be strictly newer
      // than the original report or an older sync snapshot could revive it.
      final minimum = report.updatedAt.add(const Duration(seconds: 1));
      final now = DateTime.now();
      final updatedAt = now.isAfter(minimum) ? now : minimum;
      await (_db.update(
        _db.equipmentBusyReports,
      )..where((r) => r.id.equals(id))).write(
        EquipmentBusyReportsCompanion(
          deletedAt: Value(updatedAt),
          updatedAt: Value(updatedAt),
        ),
      );
    });
  }
}
