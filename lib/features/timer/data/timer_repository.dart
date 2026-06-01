import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';

/// Persistence for the single active rest timer.
///
/// The timer is a wall-clock deadline: [start] writes `endsAt = now + duration`
/// and the UI recomputes remaining time from it, so the countdown is correct
/// even after a reload or the process being killed mid-rest.
class TimerRepository {
  TimerRepository(this._db);

  static const _singleton = 'singleton';

  final QuadrilleDatabase _db;

  /// The active timer row, or null when none is set.
  Stream<ActiveTimer?> watch() {
    return (_db.select(_db.activeTimers)..where((t) => t.id.equals(_singleton)))
        .watchSingleOrNull();
  }

  Future<ActiveTimer?> read() {
    return (_db.select(_db.activeTimers)..where((t) => t.id.equals(_singleton)))
        .getSingleOrNull();
  }

  /// Starts (or replaces) the rest timer; returns its deadline.
  Future<DateTime> start({
    required Duration duration,
    String? sessionId,
    String? sessionExerciseId,
    String? label,
  }) async {
    final now = DateTime.now();
    final endsAt = now.add(duration);
    await _db.into(_db.activeTimers).insertOnConflictUpdate(
          ActiveTimersCompanion.insert(
            id: const Value(_singleton),
            sessionId: Value(sessionId),
            sessionExerciseId: Value(sessionExerciseId),
            label: Value(label),
            startedAt: now,
            endsAt: endsAt,
            durationSeconds: duration.inSeconds,
            status: const Value(TimerStatus.running),
          ),
        );
    return endsAt;
  }

  /// Shifts the deadline by [delta] (positive to extend, negative to shorten),
  /// clamped so it never lands in the past. Returns the new deadline, or null
  /// if there is no running timer.
  Future<DateTime?> adjust(Duration delta) async {
    final current = await read();
    if (current == null) return null;
    final now = DateTime.now();
    var endsAt = current.endsAt.add(delta);
    if (endsAt.isBefore(now)) endsAt = now;
    await (_db.update(_db.activeTimers)..where((t) => t.id.equals(_singleton)))
        .write(
      ActiveTimersCompanion(
        endsAt: Value(endsAt),
        durationSeconds: Value(endsAt.difference(current.startedAt).inSeconds),
        status: const Value(TimerStatus.running),
      ),
    );
    return endsAt;
  }

  /// Removes the timer entirely (skip / dismiss).
  Future<void> clear() async {
    await (_db.delete(_db.activeTimers)..where((t) => t.id.equals(_singleton)))
        .go();
  }
}
