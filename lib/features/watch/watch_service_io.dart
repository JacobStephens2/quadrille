import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'watch_service.dart';
import 'watch_snapshot.dart';

WatchService createWatchService() => _IosWatchService();

/// Bridges to the native iOS `WatchConnectivityBridge` over a MethodChannel.
/// Calls are best-effort: if the native side isn't present yet (watch target
/// not added), `invokeMethod` throws [MissingPluginException], which we ignore.
class _IosWatchService implements WatchService {
  static const _channel = MethodChannel('app.quadrille/watch');

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    await _channel
        .invokeMethod<void>('updateSnapshot', snapshot.toMap())
        .catchError((Object _) {});
  }

  @override
  Future<void> clear() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    await _channel.invokeMethod<void>('clear').catchError((Object _) {});
  }
}
