import '../../../core/database/database.dart';

/// The original wall time at the gym, represented without further conversion.
extension EquipmentBusyReportTime on EquipmentBusyReport {
  DateTime get reportedGymTime =>
      reportedAt.toUtc().add(Duration(minutes: utcOffsetMinutes));
}

class EquipmentBusyTime {
  const EquipmentBusyTime({
    required this.weekday,
    required this.hour,
    required this.count,
  });

  final int weekday;
  final int hour;
  final int count;
}

/// Busy counts by weekday and hour, most reported times first. These are
/// observations, not occupancy rates: unreported times may also be busy.
class EquipmentBusyHistory {
  EquipmentBusyHistory(List<EquipmentBusyReport> reports)
    : reports = List.unmodifiable(reports),
      times = _groupTimes(reports);

  final List<EquipmentBusyReport> reports;
  final List<EquipmentBusyTime> times;

  static List<EquipmentBusyTime> _groupTimes(
    List<EquipmentBusyReport> reports,
  ) {
    final counts = <(int, int), int>{};
    for (final report in reports) {
      final time = report.reportedGymTime;
      final key = (time.weekday, time.hour);
      counts.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
    final times =
        [
          for (final entry in counts.entries)
            EquipmentBusyTime(
              weekday: entry.key.$1,
              hour: entry.key.$2,
              count: entry.value,
            ),
        ]..sort((a, b) {
          final count = b.count.compareTo(a.count);
          if (count != 0) return count;
          final day = a.weekday.compareTo(b.weekday);
          return day != 0 ? day : a.hour.compareTo(b.hour);
        });
    return List.unmodifiable(times);
  }
}
