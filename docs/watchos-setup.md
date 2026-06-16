# watchOS companion — architecture & release

The watch app is a native SwiftUI companion to the Flutter iOS app, bridged over
WatchConnectivity. Flutter builds only the iOS app; there is no Flutter engine for
watchOS, so no Dart or Flutter widgets run on the wrist. The phone stays the
source of truth; the watch is a thin countdown display.

The target is **wired into the Xcode project** (done in PR #1) — `flutter build
ipa` builds and embeds it automatically. This doc describes how it's structured
and how to release it. (For first-time scaffolding you no longer need to add the
target by hand; `ios/add_watch_target.rb` records how it was generated with the
`xcodeproj` gem.)

## Pieces

- `lib/features/watch/` — Dart `WatchService` (MethodChannel `app.quadrille/watch`),
  wired into `RestTimerController` so starting/skipping a rest pushes/clears a
  snapshot. No-op on web; degrades gracefully on iOS if the native side is absent.
- `ios/Runner/WatchConnectivityBridge.swift` — iOS side (member of the **Runner**
  target). Receives snapshots from Flutter and forwards them via
  `WCSession.updateApplicationContext`. Started from `AppDelegate`.
- `ios/QuadrilleWatch/` — the SwiftUI watch app (`QuadrilleWatchApp`,
  `WatchConnectivityManager`, `ActiveTimerView`), plus `Info.plist` and an
  `Assets.xcassets` AppIcon set. Bundle id `app.quadrille.watch`, paired to
  `app.quadrille`; embedded into `Runner.app/Watch/` and a build dependency of
  Runner.

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

## Build & release (iOS app + embedded watch app)

Prereqs: Flutter on PATH, Xcode, and the org App Store Connect API key (`.p8`
stored locally, not in the repo).

```sh
# 1. Generate Drift/Riverpod code — *.g.dart are NOT committed.
dart run build_runner build

# 2. Build a signed App Store IPA (iOS app + embedded watch app).
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist

# 3. Upload to TestFlight.
xcrun altool --upload-app --type ios \
  -f build/ios/ipa/quadrille.ipa \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Bump `version:` in `pubspec.yaml` (`x.y.z+build`) before each release. Both the
iOS app and the watch app read `$(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER)`, so
their versions stay in sync — the App Store requires the watch app's version to
match its host.

## Watch-target gotchas

Adding a watchOS target to a Flutter iOS project is pure Xcode-project plumbing.
Four issues each break the archive if not set; all are encoded in
`ios/Runner.xcodeproj` (and reproduced by `ios/add_watch_target.rb`):

1. **`SUPPORTED_PLATFORMS = "watchos watchsimulator"`** on the watch target.
   Otherwise it inherits `iphoneos` and `actool` rejects the watch app icon set
   ("did not have any applicable content").
2. **"Embed Watch Content" copy-files phase ordered before** Flutter's
   "Thin Binary" run-script phase, or Xcode reports a build-phase cycle.
3. **`SKIP_INSTALL = YES`** on the watch target. With `NO`, the watch app also
   installs at the archive top level, giving two apps and breaking
   `-exportArchive` ("doesn't support distributing archive").
4. **`WatchConnectivityBridge.swift` must be a member of the Runner target** — it
   is referenced by `AppDelegate`, so a missing membership fails the build with
   "cannot find 'WatchConnectivityBridge' in scope".

Both Info.plists also declare `ITSAppUsesNonExemptEncryption=false` (the app uses
only exempt HTTPS), which skips the TestFlight export-compliance prompt.

## Next (v3+, optional)

- Send commands back (skip / +30s) from the watch via `WCSession.sendMessage`
  and an `EventChannel` on the Flutter side.
- Haptic on completion via `WKInterfaceDevice.current().play(.notification)`.
