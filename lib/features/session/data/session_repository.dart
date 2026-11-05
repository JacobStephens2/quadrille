import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/ids.dart';
import '../domain/previous_session_exercise.dart';
import '../domain/session_grid.dart';

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
          ..where((s) =>
              s.status.equalsValue(SessionStatus.active) & s.deletedAt.isNull())
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

  /// Observes complete committed grids. The trigger covers current and historical
  /// data; serial snapshot reads keep exercises, sets, and references together.
  Stream<List<SessionGridRow>> watchGrid(String sessionId) => _db
      .customSelect(
        'SELECT 1',
        readsFrom: {_db.workoutSessions, _db.sessionExercises, _db.setEntries},
      )
      .watch()
      .asyncMap((_) => readGrid(sessionId));

  /// Last completed exercise before this session began, preferring the same
  /// template row even when its display name has since changed. Name matching
  /// is the fallback for recreated rows and exercises on other templates.
  Future<Map<String, PreviousSessionExercise>> _readPreviousExercises(
    String sessionId,
  ) async {
    final current = _db.alias(_db.sessionExercises, 'current_exercise');
    final active = _db.alias(_db.workoutSessions, 'current_session');
    final previous = _db.sessionExercises;
    final session = _db.workoutSessions;
    final entries = _db.setEntries;
    final sameSource =
        current.sourceTemplateExerciseId.isNotNull() &
        previous.sourceTemplateExerciseId.isNotNull() &
        previous.sourceTemplateExerciseId.equalsExp(
          current.sourceTemplateExerciseId,
        );
    final query =
        _db.select(current).join([
            innerJoin(active, active.id.equalsExp(current.sessionId)),
            innerJoin(
              previous,
              sameSource | previous.displayName.equalsExp(current.displayName),
            ),
            innerJoin(session, session.id.equalsExp(previous.sessionId)),
            leftOuterJoin(
              entries,
              entries.sessionExerciseId.equalsExp(previous.id) &
                  entries.status.equalsValue(SetStatus.completed) &
                  entries.completedAt.isNotNull() &
                  entries.deletedAt.isNull(),
            ),
          ])
          ..where(
            current.sessionId.equals(sessionId) &
                current.deletedAt.isNull() &
                active.deletedAt.isNull() &
                previous.deletedAt.isNull() &
                session.deletedAt.isNull() &
                session.id.equals(sessionId).not() &
                session.status.equalsValue(SessionStatus.completed) &
                session.completedAt.isSmallerOrEqual(active.startedAt),
          )
          ..orderBy([
            OrderingTerm(expression: sameSource, mode: OrderingMode.desc),
            OrderingTerm(
              expression: session.completedAt,
              mode: OrderingMode.desc,
            ),
            OrderingTerm(
              expression: session.startedAt,
              mode: OrderingMode.desc,
            ),
            OrderingTerm(expression: previous.id),
            OrderingTerm(expression: entries.setNumber),
          ]);
    final history = <String, PreviousSessionExercise>{};
    for (final row in await query.get()) {
      final currentId = row.readTable(current).id;
      final snapshot = row.readTable(previous);
      final reference = history.putIfAbsent(
        currentId,
        () => PreviousSessionExercise(exercise: snapshot, sets: []),
      );
      if (reference.exercise.id == snapshot.id) {
        final set = row.readTableOrNull(entries);
        if (set != null) reference.sets.add(set);
      }
    }
    return history;
  }

  /// Complete Session grid from one database snapshot, including history.
  /// Works independently of UI subscriptions, including immediately after writes.
  Future<List<SessionGridRow>> readGrid(String sessionId) =>
      _db.transaction(() async {
        final session = await (_db.select(_db.workoutSessions)
              ..where((s) => s.id.equals(sessionId) & s.deletedAt.isNull()))
            .getSingleOrNull();
        if (session == null) return [];
        final exercises =
            await (_db.select(_db.sessionExercises)
                  ..where(
                    (e) => e.sessionId.equals(sessionId) & e.deletedAt.isNull(),
                  )
                  ..orderBy([(e) => OrderingTerm(expression: e.sortIndex)]))
                .get();
        final sets =
            await (_db.select(_db.setEntries)..where(
                  (s) =>
                      s.sessionExerciseId.isIn(exercises.map((e) => e.id)) &
                      s.deletedAt.isNull(),
                ))
                .get();
        final previous = await _readPreviousExercises(sessionId);
        return _assembleGrid(exercises, sets, previous);
      });

  List<SessionGridRow> _assembleGrid(
    List<SessionExercise> exercises,
    List<SetEntry> sets,
    Map<String, PreviousSessionExercise> previous,
  ) {
    final byExercise = <String, List<SetEntry>>{};
    for (final set in sets) {
      (byExercise[set.sessionExerciseId] ??= []).add(set);
    }
    return [
      for (final exercise in exercises)
        SessionGridRow(
          exercise: exercise,
          sets: (byExercise[exercise.id] ?? [])
            ..sort((a, b) => a.setNumber.compareTo(b.setNumber)),
          previous: previous[exercise.id],
        ),
    ];
  }

  /// Completed sessions, newest first (history list).
  Stream<List<WorkoutSession>> watchHistory() {
    return (_db.select(_db.workoutSessions)
          ..where((s) =>
              s.status.equalsValue(SessionStatus.completed) &
              s.deletedAt.isNull())
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
            ..where((e) => e.templateId.equals(templateId) & e.deletedAt.isNull())
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
              generalNotes: Value(template.notes),
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

  /// Records a set, including optional RPE and lengthened partials.
  /// Marks it completed by default, bumping `completedAt`.
  Future<void> saveSet(
    String setEntryId, {
    double? weight,
    int? reps,
    int? leftReps,
    int? rightReps,
    double? rpe,
    int? partials,
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
        rpe: Value(rpe),
        partials: Value(partials),
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

  /// Soft-deletes a set (tombstone) so the deletion propagates on sync.
  Future<void> deleteSet(String setEntryId) async {
    final now = DateTime.now();
    await (_db.update(_db.setEntries)..where((s) => s.id.equals(setEntryId)))
        .write(SetEntriesCompanion(deletedAt: Value(now), updatedAt: Value(now)));
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

  /// Discards a session by tombstoning it (and its set entries) so the
  /// deletion propagates on sync rather than resurrecting from another device.
  Future<void> discardSession(String sessionId) async {
    final now = DateTime.now();
    await _db.transaction(() async {
      await (_db.update(_db.workoutSessions)..where((s) => s.id.equals(sessionId)))
          .write(
        WorkoutSessionsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      final exerciseIds = (await (_db.select(_db.sessionExercises)
                ..where((e) => e.sessionId.equals(sessionId)))
              .get())
          .map((e) => e.id)
          .toList();
      await (_db.update(_db.sessionExercises)
            ..where((e) => e.sessionId.equals(sessionId)))
          .write(SessionExercisesCompanion(
              deletedAt: Value(now), updatedAt: Value(now)));
      if (exerciseIds.isNotEmpty) {
        await (_db.update(_db.setEntries)
              ..where((s) => s.sessionExerciseId.isIn(exerciseIds)))
            .write(
                SetEntriesCompanion(deletedAt: Value(now), updatedAt: Value(now)));
      }
    });
  }

  /// Saves trimmed session notes; null or blank input clears them.
  Future<void> setSessionNotes(String sessionId, String? notes) async {
    final trimmed = notes?.trim();
    await (_db.update(_db.workoutSessions)..where((s) => s.id.equals(sessionId)))
        .write(
      WorkoutSessionsCompanion(
        generalNotes: Value(trimmed == null || trimmed.isEmpty ? null : trimmed),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
