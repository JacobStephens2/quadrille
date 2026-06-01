import Foundation
import WatchConnectivity

/// Receives the current rest snapshot pushed from the iPhone via
/// WatchConnectivity application context, and exposes it to SwiftUI.
final class WatchConnectivityManager: NSObject, ObservableObject {
  static let shared = WatchConnectivityManager()

  /// Exercise the current rest follows (nil when no rest is active).
  @Published var exerciseName: String?

  /// Rest deadline as epoch milliseconds (nil when no rest is active).
  @Published var restEndsAtMillis: Double?

  override init() {
    super.init()
    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
  }

  private func apply(_ context: [String: Any]) {
    DispatchQueue.main.async {
      if context["cleared"] as? Bool == true {
        self.exerciseName = nil
        self.restEndsAtMillis = nil
        return
      }
      self.exerciseName = context["exerciseName"] as? String
      self.restEndsAtMillis = context["restEndsAtMillis"] as? Double
        ?? (context["restEndsAtMillis"] as? Int).map(Double.init)
    }
  }
}

extension WatchConnectivityManager: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    apply(context)
  }
}
