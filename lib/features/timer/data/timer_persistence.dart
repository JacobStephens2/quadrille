part of '../timer_providers.dart';

/// Private persistence for the module's singleton wall-clock countdown.
class _TimerPersistence {
  _TimerPersistence(this._db, this._now);

  static const _singleton = 'singleton';
  final QuadrilleDatabase _db;
  final DateTime Function() _now;

  Object get generation => _db.timerGeneration;

  Stream<ActiveTimer?> watch() => _query().watchSingleOrNull();

  SimpleSelectStatement<$ActiveTimersTable, ActiveTimer> _query() =>
      _db.select(_db.activeTimers)..where((t) => t.id.equals(_singleton));

  Future<ActiveTimer?> start({
    required Duration duration,
    required Object generation,
    String? sessionId,
    String? sessionExerciseId,
    String? label,
  }) => _db.transaction(() async {
    if (!identical(generation, _db.timerGeneration)) return null;
    final now = _now();
    await _db
        .into(_db.activeTimers)
        .insertOnConflictUpdate(
          ActiveTimersCompanion.insert(
            id: const Value(_singleton),
            sessionId: Value(sessionId),
            sessionExerciseId: Value(sessionExerciseId),
            label: Value(label),
            startedAt: now,
            endsAt: now.add(duration),
            durationSeconds: duration.inSeconds,
            status: const Value(TimerStatus.running),
          ),
        );
    return _query().getSingle();
  });

  Future<ActiveTimer?> adjust(Duration delta) => _db.transaction(() async {
    final current = await _query().getSingleOrNull();
    if (current == null) return null;
    final now = _now();
    var endsAt = current.endsAt.add(delta);
    if (endsAt.isBefore(now)) endsAt = now;
    await (_db.update(
      _db.activeTimers,
    )..where((t) => t.id.equals(_singleton))).write(
      ActiveTimersCompanion(
        endsAt: Value(endsAt),
        durationSeconds: Value(endsAt.difference(current.startedAt).inSeconds),
        status: const Value(TimerStatus.running),
      ),
    );
    return _query().getSingle();
  });

  Future<void> clear() async {
    await (_db.delete(
      _db.activeTimers,
    )..where((t) => t.id.equals(_singleton))).go();
  }
}
