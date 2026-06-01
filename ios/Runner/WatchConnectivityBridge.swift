import Flutter
import WatchConnectivity

/// iOS side of the watch bridge: receives rest snapshots from Flutter over a
/// MethodChannel and forwards them to the paired Apple Watch via
/// WatchConnectivity (applicationContext = latest-state delivery, ideal for a
/// single "current rest").
///
/// NOTE: This is scaffolding. It compiles into the iOS Runner, but the watch
/// experience only works once the watchOS target is added in Xcode and this
/// bridge is started from AppDelegate (see docs/watchos-setup.md).
final class WatchConnectivityBridge: NSObject {
  static let shared = WatchConnectivityBridge()

  private var channel: FlutterMethodChannel?

  func start(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "app.quadrille/watch",
      binaryMessenger: messenger
    )
    channel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }

    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard WCSession.isSupported() else { result(nil); return }
    switch call.method {
    case "updateSnapshot":
      if let args = call.arguments as? [String: Any] {
        try? WCSession.default.updateApplicationContext(args)
      }
      result(nil)
    case "clear":
      try? WCSession.default.updateApplicationContext(["cleared": true])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

extension WatchConnectivityBridge: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // Re-activate for a newly paired watch.
    WCSession.default.activate()
  }
}
