import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../domain/exercise_history.dart';

/// Builds per-exercise history across completed sessions, matched by display
/// name (case-insensitive) so it groups both catalog-linked and free-text
/// entries the way the user sees them.
class ExerciseHistoryService {
  ExerciseHistoryService(this._db);

  final QuadrilleDatabase _db;

  Future<ExerciseHistory> forName(String displayName) async {
    final se = _db.sessionExercises;
    final ws = _db.workoutSessions;
    final entries = _db.setEntries;

    final query = _db.select(entries).join([
      innerJoin(se, se.id.equalsExp(entries.sessionExerciseId)),
      innerJoin(ws, ws.id.equalsExp(se.sessionId)),
    ])
      ..where(se.displayName.lower().equals(displayName.toLowerCase()) &
          ws.status.equalsValue(SessionStatus.completed) &
          entries.completedAt.isNotNull())
      ..orderBy([
        OrderingTerm(expression: ws.startedAt, mode: OrderingMode.desc),
        OrderingTerm(expression: entries.setNumber),
      ]);

    final rows = await query.get();

    // Group into sessions, preserving the date-desc order of first appearance.
    final order = <String>[];
    final bySession = <String, ExerciseHistorySession>{};
    for (final row in rows) {
      final session = row.readTable(ws);
      final set = row.readTable(entries);
      final existing = bySession[session.id];
      if (existing == null) {
        order.add(session.id);
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

    return buildExerciseHistory([for (final id in order) bySession[id]!]);
  }
}
