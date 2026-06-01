import 'dart:async';
import 'dart:io' show Platform;

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
  void updateSnapshot(WatchSnapshot snapshot) {
    if (!Platform.isIOS) return;
    unawaited(
      _channel.invokeMethod('updateSnapshot', snapshot.toMap()).catchError(
        (_) => null,
      ),
    );
  }

  @override
  void clear() {
    if (!Platform.isIOS) return;
    unawaited(_channel.invokeMethod('clear').catchError((_) => null));
  }
}
