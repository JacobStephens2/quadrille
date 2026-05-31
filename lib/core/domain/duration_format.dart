/// Formatting and parsing for rest intervals, matching the sheet's notation
/// (`90s`, `2'`, `2.5'`, `3'`, `60s`). Internally everything is seconds.
extension RestDurationFormat on Duration {
  /// Compact label as written on the sheet. Sub-two-minute intervals stay in
  /// seconds (`60s`, `90s`); two minutes and up collapse to minutes with an
  /// apostrophe on whole/half-minute boundaries (`2'`, `2.5'`, `3'`). Zero
  /// renders as `0s`.
  String get restLabel {
    final totalSeconds = inSeconds;
    if (totalSeconds == 0) return '0s';
    if (totalSeconds >= 120) {
      if (totalSeconds % 60 == 0) return "${totalSeconds ~/ 60}'";
      if (totalSeconds % 30 == 0) {
        return "${(totalSeconds / 60).toStringAsFixed(1)}'";
      }
    }
    return '${totalSeconds}s';
  }

  /// `MM:SS` clock label for the live countdown ring (`01:24`).
  String get clockLabel {
    final negative = isNegative;
    final s = inSeconds.abs();
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '${negative ? '-' : ''}$mm:$ss';
  }
}

/// Parses a rest interval written in sheet notation. Accepts `90s`, `90`,
/// `2'`, `2.5'`, `1:30`, or `1m30s`. Returns null when unparseable.
Duration? parseRest(String raw) {
  final text = raw.trim().toLowerCase();
  if (text.isEmpty) return null;

  // MM:SS form.
  final clock = RegExp(r'^(\d+):(\d{1,2})$').firstMatch(text);
  if (clock != null) {
    return Duration(
      minutes: int.parse(clock.group(1)!),
      seconds: int.parse(clock.group(2)!),
    );
  }

  // Minutes with apostrophe (2', 2.5').
  final mins = RegExp(r"^(\d+(?:\.\d+)?)\s*'$").firstMatch(text);
  if (mins != null) {
    return Duration(seconds: (double.parse(mins.group(1)!) * 60).round());
  }

  // Seconds (90s, 90).
  final secs = RegExp(r'^(\d+)\s*s?$').firstMatch(text);
  if (secs != null) {
    return Duration(seconds: int.parse(secs.group(1)!));
  }

  // Combined 1m30s.
  final combined =
      RegExp(r'^(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?$').firstMatch(text);
  if (combined != null && (combined.group(1) != null || combined.group(2) != null)) {
    return Duration(
      minutes: int.tryParse(combined.group(1) ?? '') ?? 0,
      seconds: int.tryParse(combined.group(2) ?? '') ?? 0,
    );
  }

  return null;
}
