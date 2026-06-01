import SwiftUI

// watchOS companion app entry point.
//
// SCAFFOLD: these sources are not yet part of an Xcode target. Add a watchOS
// App target in Xcode and include this folder's files in it
// (see docs/watchos-setup.md).
@main
struct QuadrilleWatchApp: App {
  @StateObject private var connectivity = WatchConnectivityManager.shared

  var body: some Scene {
    WindowGroup {
      ActiveTimerView()
        .environmentObject(connectivity)
    }
  }
}
