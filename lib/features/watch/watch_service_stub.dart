import 'watch_service.dart';
import 'watch_snapshot.dart';

/// No watch on web/desktop.
WatchService createWatchService() => _NoopWatchService();

class _NoopWatchService implements WatchService {
  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {}

  @override
  Future<void> clear() async {}
}
