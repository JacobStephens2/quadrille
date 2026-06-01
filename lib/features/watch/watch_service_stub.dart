import 'watch_service.dart';
import 'watch_snapshot.dart';

/// No watch on web/desktop.
WatchService createWatchService() => _NoopWatchService();

class _NoopWatchService implements WatchService {
  @override
  void updateSnapshot(WatchSnapshot snapshot) {}

  @override
  void clear() {}
}
