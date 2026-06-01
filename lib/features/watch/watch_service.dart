library;

import 'watch_snapshot.dart';

export 'watch_service_stub.dart'
    if (dart.library.io) 'watch_service_io.dart';

/// Sends the active-rest snapshot to a paired Apple Watch (v3). Implemented
/// over a MethodChannel on iOS; a no-op everywhere else. Until the native
/// watch target is added in Xcode (see docs/watchos-setup.md), the iOS
/// implementation degrades gracefully to a no-op.
abstract interface class WatchService {
  /// Pushes the current rest countdown to the watch.
  void updateSnapshot(WatchSnapshot snapshot);

  /// Tells the watch the rest ended / was cleared.
  void clear();
}
