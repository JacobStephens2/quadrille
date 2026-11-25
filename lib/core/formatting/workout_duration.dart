// Overall workout length, measured from Session starting: `startedAt` is
// stamped when the template is snapshotted, before the primer dialog and
// grid open, so the primer counts toward the total. Do not redefine the
// start point here; see the Workout duration entry in GLOSSARY.md.

/// Live elapsed label: `MM:SS` under an hour, `H:MM:SS` at an hour and up.
/// Hours are never capped or rolled into days, so a stale session resumed
/// days later shows its true elapsed (for example `72:00:00`). A negative
/// elapsed (backwards clock) clamps to `00:00`.
String workoutElapsedLabel(Duration elapsed) {
  final totalSeconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours == 0 ? '$mm:$ss' : '$hours:$mm:$ss';
}

/// Total length of a finished workout (`completedAt - startedAt`) in compact
/// history form: `<1m` under a minute, `48m` under an hour, then `1h 12m`
/// (zero minutes dropped: `2h`). Minutes round to the nearest minute.
///
/// Returns null - omit the duration entirely - when [completedAt] is null or
/// not after [startedAt], so history never shows zero or a negative length.
String? workoutDurationLabel({
  required DateTime startedAt,
  required DateTime? completedAt,
}) {
  if (completedAt == null || !completedAt.isAfter(startedAt)) return null;
  final total = completedAt.difference(startedAt);
  if (total < const Duration(minutes: 1)) return '<1m';
  final minutes = (total.inSeconds / 60).round();
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}
