# watchOS companion — setup (Mac required)

The watch app is **scaffolded** in the repo but not yet wired into an Xcode
target. Flutter cannot build watchOS, so the watch surface is a native SwiftUI
app bridged to the Flutter iOS app over WatchConnectivity. The phone stays the
source of truth; the watch is a thin countdown display.

## What's already in the repo

- `lib/features/watch/` — Dart `WatchService` (MethodChannel `app.quadrille/watch`),
  wired into `RestTimerController` so starting/skipping a rest pushes/clears a
  snapshot. No-op on web; degrades gracefully on iOS until the native side exists.
- `ios/Runner/WatchConnectivityBridge.swift` — iOS side: receives snapshots from
  Flutter and forwards them via `WCSession.updateApplicationContext`. Started
  from `AppDelegate`.
- `ios/QuadrilleWatch/` — the SwiftUI watch app (`QuadrilleWatchApp`,
  `WatchConnectivityManager`, `ActiveTimerView`).

## Steps in Xcode (on your Mac)

1. `cd quadrille && flutter build ios --config-only` (generates the iOS project).
2. Open `ios/Runner.xcworkspace`.
3. **File ▸ New ▸ Target… ▸ watchOS ▸ App.** Name it `QuadrilleWatch`,
   interface **SwiftUI**, bundle id `app.quadrille.watch` (paired to
   `app.quadrille`).
4. Delete the auto-generated `ContentView.swift`/`App.swift` in the new target
   and instead **add the files from `ios/QuadrilleWatch/`** to the watch target.
5. Confirm `WatchConnectivityBridge.swift` is a member of the **Runner** target
   (it ships in the iOS app).
6. Add the **WatchConnectivity** framework if Xcode doesn't link it
   automatically (it's part of the SDK; `import WatchConnectivity` should just
   work).
7. Build & run the watch scheme on a paired simulator/device.

## How it flows

```
log a set / start rest
  -> RestTimerController.start (Dart)
  -> WatchService.updateSnapshot  --MethodChannel-->  WatchConnectivityBridge (iOS)
  -> WCSession.updateApplicationContext
  -> WatchConnectivityManager (watchOS)  ->  ActiveTimerView countdown
```

The watch recomputes remaining time from the absolute `restEndsAtMillis`
deadline, so it stays correct without the phone streaming ticks.

## Next (v3+, optional)

- Send commands back (skip / +30s) from the watch via `WCSession.sendMessage`
  and an `EventChannel` on the Flutter side.
- Haptic on completion via `WKInterfaceDevice.current().play(.notification)`.
