part of '../timer_providers.dart';

/// Rolls an in-flight Rest timer write back when its generation was retired.
class _StaleTimerGeneration implements Exception {
  const _StaleTimerGeneration();
}

/// Private persistence for the module's singleton wall-clock countdown.
class _TimerPersistence {
  _TimerPersistence(this._db, this._now);

  static const _singleton = 'singleton';
  final QuadrilleDatabase _db;
  final DateTime Function() _now;

  Object get generation => _db.timerGeneration;

  bool get acceptsRestTimerWrites => _db.acceptsRestTimerWrites;

  void sealRestTimer() => _db.sealRestTimer();

  void Function() holdRestTimerDuringTransition() =>
      _db.holdRestTimerDuringTransition();

  Stream<ActiveTimer?> watch() => _query().watchSingleOrNull();

  Future<ActiveTimer?> read() => _query().getSingleOrNull();

  SimpleSelectStatement<$ActiveTimersTable, ActiveTimer> _query() =>
      _db.select(_db.activeTimers)..where((t) => t.id.equals(_singleton));

  bool _isCurrent(Object generation) =>
      identical(generation, _db.timerGeneration) && _db.acceptsRestTimerWrites;

  Future<ActiveTimer?> _writeTimer({
    required Object generation,
    required Future<bool> Function() write,
  }) => _db
      .transaction(() async {
        if (!_isCurrent(generation)) return null;
        if (!await write()) return null;
        if (!_isCurrent(generation)) throw const _StaleTimerGeneration();
        return _query().getSingle();
      })
      .onError<Object>((Object error, StackTrace stack) {
        if (error is _StaleTimerGeneration) return null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<ActiveTimer?> start({
    required Duration duration,
    required Object generation,
    String? sessionId,
    String? sessionExerciseId,
    String? label,
  }) => _writeTimer(
    generation: generation,
    write: () async {
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
      return true;
    },
  );

  Future<ActiveTimer?> adjust({
    required Duration delta,
    required Object generation,
  }) => _writeTimer(
    generation: generation,
    write: () async {
      final current = await _query().getSingleOrNull();
      if (current == null) return false;
      final now = _now();
      var endsAt = current.endsAt.add(delta);
      if (endsAt.isBefore(now)) endsAt = now;
      await (_db.update(
        _db.activeTimers,
      )..where((t) => t.id.equals(_singleton))).write(
        ActiveTimersCompanion(
          endsAt: Value(endsAt),
          durationSeconds: Value(
            endsAt.difference(current.startedAt).inSeconds,
          ),
          status: const Value(TimerStatus.running),
        ),
      );
      return true;
    },
  );

  Future<bool> clear({required Object generation}) async {
    if (!_isCurrent(generation)) return false;
    await (_db.delete(
      _db.activeTimers,
    )..where((t) => t.id.equals(_singleton))).go();
    return _isCurrent(generation);
  }
}
