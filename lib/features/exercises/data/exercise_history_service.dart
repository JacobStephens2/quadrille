import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../domain/exercise_history.dart';

/// Observes complete Exercise history snapshots within one Local profile.
/// Display names match case-insensitively, independently of catalog/template
/// identity. The joined selection observes all contributing tables and emits
/// committed rows together, including an initially empty history.
class ExerciseHistoryService {
  ExerciseHistoryService(this._db);

  final QuadrilleDatabase _db;

  Stream<ExerciseHistory> watchForName(String displayName) {
    final se = _db.sessionExercises;
    final ws = _db.workoutSessions;
    final entries = _db.setEntries;

    final query =
        _db.select(entries).join([
            innerJoin(se, se.id.equalsExp(entries.sessionExerciseId)),
            innerJoin(ws, ws.id.equalsExp(se.sessionId)),
          ])
          ..where(
            se.displayName.lower().equals(displayName.toLowerCase()) &
                se.deletedAt.isNull() &
                ws.deletedAt.isNull() &
                ws.status.equalsValue(SessionStatus.completed) &
                entries.deletedAt.isNull() &
                entries.status.equalsValue(SetStatus.completed) &
                entries.completedAt.isNotNull(),
          )
          ..orderBy([
            OrderingTerm(expression: ws.startedAt, mode: OrderingMode.desc),
            OrderingTerm(expression: ws.id),
            OrderingTerm(expression: entries.setNumber),
            OrderingTerm(expression: se.sortIndex),
            OrderingTerm(expression: se.id),
            OrderingTerm(expression: entries.id),
          ]);

    return query.watch().map(_fromRows);
  }

  ExerciseHistory _fromRows(List<TypedResult> rows) {
    final ws = _db.workoutSessions;
    final entries = _db.setEntries;

    // Dart maps preserve insertion order from the sorted joined rows.
    final bySession = <String, ExerciseHistorySession>{};
    for (final row in rows) {
      final session = row.readTable(ws);
      final set = row.readTable(entries);
      final existing = bySession[session.id];
      if (existing == null) {
        bySession[session.id] = ExerciseHistorySession(
          sessionId: session.id,
          sessionName: session.name,
          date: session.startedAt,
          sets: [set],
        );
      } else {
        existing.sets.add(set);
      }
    }

    final sessions = bySession.values.toList();
    double? heaviest;
    double? bestE1rm;
    SetEntry? bestSet;
    for (final session in sessions) {
      for (final set in session.sets) {
        if (set.weight != null &&
            (heaviest == null || set.weight! > heaviest)) {
          heaviest = set.weight;
        }
        final e1rm = estimatedOneRepMax(set);
        if (e1rm != null && (bestE1rm == null || e1rm > bestE1rm)) {
          bestE1rm = e1rm;
          bestSet = set;
        }
      }
    }
    return ExerciseHistory(
      sessions: sessions,
      stats: ExerciseStats(
        heaviestWeight: heaviest,
        bestEstimatedOneRepMax: bestE1rm,
        bestSet: bestSet,
        lastPerformed: sessions.isEmpty ? null : sessions.first.date,
        sessionCount: sessions.length,
      ),
    );
  }
}
