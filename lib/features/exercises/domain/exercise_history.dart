import 'package:flutter/foundation.dart';

import '../../../core/database/database.dart';

/// Estimated one-rep max from a logged set (Epley: w·(1 + reps/30)).
/// Null unless the set has both a weight and reps.
double? estimatedOneRepMax(SetEntry set) {
  final w = set.weight;
  final reps = set.reps;
  if (w == null || reps == null || reps <= 0) return null;
  return w * (1 + reps / 30.0);
}

/// One past session in which the exercise was performed, with its logged sets.
@immutable
class ExerciseHistorySession {
  const ExerciseHistorySession({
    required this.sessionId,
    required this.sessionName,
    required this.date,
    required this.sets,
  });

  final String sessionId;
  final String sessionName;
  final DateTime date;
  final List<SetEntry> sets;

  /// Best estimated 1RM among this session's sets.
  double? get bestEstimatedOneRepMax {
    double? best;
    for (final s in sets) {
      final e = estimatedOneRepMax(s);
      if (e != null && (best == null || e > best)) best = e;
    }
    return best;
  }
}

/// All-time personal records for an exercise.
@immutable
class ExerciseStats {
  const ExerciseStats({
    this.heaviestWeight,
    this.bestEstimatedOneRepMax,
    this.bestSet,
    this.lastPerformed,
    this.sessionCount = 0,
  });

  final double? heaviestWeight;
  final double? bestEstimatedOneRepMax;

  /// The set with the highest estimated 1RM (the "best" working set).
  final SetEntry? bestSet;
  final DateTime? lastPerformed;
  final int sessionCount;

  bool get isEmpty => sessionCount == 0;
}

/// History + PRs for one exercise (matched by display name).
@immutable
class ExerciseHistory {
  const ExerciseHistory({required this.sessions, required this.stats});

  final List<ExerciseHistorySession> sessions;
  final ExerciseStats stats;

  static const empty =
      ExerciseHistory(sessions: [], stats: ExerciseStats());
}

/// Folds a flat, date-desc list of (session, set) rows into grouped history and
/// computes personal records.
ExerciseHistory buildExerciseHistory(
  List<ExerciseHistorySession> sessions,
) {
  double? heaviest;
  double? bestE1rm;
  SetEntry? bestSet;
  for (final session in sessions) {
    for (final s in session.sets) {
      if (s.weight != null && (heaviest == null || s.weight! > heaviest)) {
        heaviest = s.weight;
      }
      final e1rm = estimatedOneRepMax(s);
      if (e1rm != null && (bestE1rm == null || e1rm > bestE1rm)) {
        bestE1rm = e1rm;
        bestSet = s;
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
