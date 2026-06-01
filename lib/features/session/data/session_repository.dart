import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/ids.dart';

/// Persistence for live and historical workout sessions.
///
/// The defining behaviour is [startFromTemplate]: it *snapshots* the template
/// rows into `session_exercises` and pre-creates empty `set_entries`, so the
/// grid opens pre-filled (no recopying) and later template edits never mutate
/// recorded history.
class SessionRepository {
  SessionRepository(this._db);

  final QuadrilleDatabase _db;

  /// The most recent still-active session, if any (drives "resume" on Today).
  Stream<WorkoutSession?> watchActiveSession() {
    return (_db.select(_db.workoutSessions)
          ..where((s) => s.status.equalsValue(SessionStatus.active))
          ..orderBy([
            (s) => OrderingTerm(expression: s.startedAt, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .watchSingleOrNull();
  }

  Stream<WorkoutSession?> watchSession(String sessionId) {
    return (_db.select(_db.workoutSessions)..where((s) => s.id.equals(sessionId)))
        .watchSingleOrNull();
  }

  /// Exercise rows of a session, in sheet order.
  Stream<List<SessionExercise>> watchExercises(String sessionId) {
    return (_db.select(_db.sessionExercises)
          ..where((e) => e.sessionId.equals(sessionId))
          ..orderBy([(e) => OrderingTerm(expression: e.sortIndex)]))
        .watch();
  }

  /// Every set entry for a session (joined through its exercises), ordered by
  /// exercise then set number — ready to group into grid rows.
  Stream<List<SetEntry>> watchSets(String sessionId) {
    final query = _db.select(_db.setEntries).join([
      innerJoin(
        _db.sessionExercises,
        _db.sessionExercises.id.equalsExp(_db.setEntries.sessionExerciseId),
      ),
    ])
      ..where(_db.sessionExercises.sessionId.equals(sessionId))
      ..orderBy([
        OrderingTerm(expression: _db.sessionExercises.sortIndex),
        OrderingTerm(expression: _db.setEntries.setNumber),
      ]);
    return query.watch().map(
          (rows) => rows.map((r) => r.readTable(_db.setEntries)).toList(),
        );
  }

  /// Completed sessions, newest first (history list).
  Stream<List<WorkoutSession>> watchHistory() {
    return (_db.select(_db.workoutSessions)
          ..where((s) => s.status.equalsValue(SessionStatus.completed))
          ..orderBy([
            (s) => OrderingTerm(expression: s.startedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Starts a new session from a template: copies the template's exercise rows
  /// into `session_exercises` and pre-creates `plannedSets` empty set rows.
  Future<String> startFromTemplate(String templateId) async {
    return _db.transaction(() async {
      final template = await (_db.select(_db.workoutTemplates)
            ..where((t) => t.id.equals(templateId)))
          .getSingle();
      final templateRows = await (_db.select(_db.templateExercises)
            ..where((e) => e.templateId.equals(templateId))
            ..orderBy([(e) => OrderingTerm(expression: e.sortIndex)]))
          .get();
      final unit = (await _db.select(_db.appSettingsTable).getSingle()).units;

      final now = DateTime.now();
      final sessionId = newId();
      await _db.into(_db.workoutSessions).insert(
            WorkoutSessionsCompanion.insert(
              id: sessionId,
              templateId: Value(templateId),
              name: template.name,
              status: const Value(SessionStatus.active),
              startedAt: now,
              createdAt: now,
              updatedAt: now,
            ),
          );

      for (final row in templateRows) {
        final sessionExerciseId = newId();
        await _db.into(_db.sessionExercises).insert(
              SessionExercisesCompanion.insert(
                id: sessionExerciseId,
                sessionId: sessionId,
                sourceTemplateExerciseId: Value(row.id),
                displayName: row.displayName,
                orderLabel: row.orderLabel,
                sortIndex: row.sortIndex,
                supersetGroup: Value(row.supersetGroup),
                plannedSets: Value(row.targetSets),
                repMin: Value(row.repMin),
                repMax: Value(row.repMax),
                durationMinSeconds: Value(row.durationMinSeconds),
                durationMaxSeconds: Value(row.durationMaxSeconds),
                plannedRestSeconds: Value(row.restSeconds),
                plannedNotes: Value(row.notes),
                isUnilateral: Value(row.isUnilateral),
                loadKind: Value(row.loadKind),
                createdAt: now,
                updatedAt: now,
              ),
            );
        await _db.batch((batch) {
          for (var n = 1; n <= row.targetSets; n++) {
            batch.insert(
              _db.setEntries,
              SetEntriesCompanion.insert(
                id: newId(),
                sessionExerciseId: sessionExerciseId,
                setNumber: n,
                weightUnit: Value(unit),
                createdAt: now,
                updatedAt: now,
              ),
            );
          }
        });
      }
      return sessionId;
    });
  }

  /// Records weight/reps for a set. Marks it completed by default (the common
  /// path: you log a set you just did), bumping `completedAt`.
  Future<void> saveSet(
    String setEntryId, {
    double? weight,
    int? reps,
    int? leftReps,
    int? rightReps,
    String? notes,
    SetStatus status = SetStatus.completed,
  }) async {
    final now = DateTime.now();
    await (_db.update(_db.setEntries)..where((s) => s.id.equals(setEntryId)))
        .write(
      SetEntriesCompanion(
        weight: Value(weight),
        reps: Value(reps),
        leftReps: Value(leftReps),
        rightReps: Value(rightReps),
        notes: Value(notes),
        status: Value(status),
        completedAt:
            Value(status == SetStatus.completed ? now : null),
        updatedAt: Value(now),
      ),
    );
  }

  /// Appends an extra set to an exercise (e.g. an unplanned bonus set).
  Future<String> addSet(String sessionExerciseId) async {
    final now = DateTime.now();
    final existing = await (_db.select(_db.setEntries)
          ..where((s) => s.sessionExerciseId.equals(sessionExerciseId)))
        .get();
    final nextNumber =
        existing.fold(0, (m, s) => s.setNumber > m ? s.setNumber : m) + 1;
    final id = newId();
    final unit = existing.isNotEmpty ? existing.first.weightUnit : WeightUnit.lb;
    await _db.into(_db.setEntries).insert(
          SetEntriesCompanion.insert(
            id: id,
            sessionExerciseId: sessionExerciseId,
            setNumber: nextNumber,
            weightUnit: Value(unit),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> deleteSet(String setEntryId) async {
    await (_db.delete(_db.setEntries)..where((s) => s.id.equals(setEntryId)))
        .go();
  }

  /// Marks a session finished.
  Future<void> completeSession(String sessionId) async {
    final now = DateTime.now();
    await (_db.update(_db.workoutSessions)..where((s) => s.id.equals(sessionId)))
        .write(
      WorkoutSessionsCompanion(
        status: const Value(SessionStatus.completed),
        completedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  /// Permanently discards a session and its rows (FK cascade).
  Future<void> discardSession(String sessionId) async {
    await (_db.delete(_db.workoutSessions)..where((s) => s.id.equals(sessionId)))
        .go();
  }

  Future<void> setSessionNotes(String sessionId, String? notes) async {
    await (_db.update(_db.workoutSessions)..where((s) => s.id.equals(sessionId)))
        .write(
      WorkoutSessionsCompanion(
        generalNotes: Value(notes),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
