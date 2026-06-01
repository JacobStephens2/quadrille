/// A tiny snapshot of the active rest sent to the watch. The watch is a thin
/// display/control surface — the phone stays the source of truth — so this
/// carries only what the wrist needs to show a countdown.
class WatchSnapshot {
  const WatchSnapshot({
    required this.exerciseName,
    required this.restEndsAtMillis,
  });

  /// The exercise the rest follows (shown on the watch).
  final String exerciseName;

  /// Wall-clock deadline as epoch millis; the watch computes remaining itself.
  final int restEndsAtMillis;

  Map<String, Object?> toMap() => {
        'exerciseName': exerciseName,
        'restEndsAtMillis': restEndsAtMillis,
      };
}
