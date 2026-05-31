# Quadrille

> The workout sheet that times your rest.

Quadrille is a local-first, cross-platform weightlifting tracker built in Flutter/Dart.
It digitizes the paper "quadrille grid" workflow: reusable Push/Pull/Legs templates,
ordered exercises (with superset groups), per-exercise rest intervals, and a
spreadsheet-style grid for logging weight × reps per set — with an integrated,
reliable rest timer that buzzes your wrist when it's time for the next set.

## Targets

| Platform | Status | How |
| --- | --- | --- |
| Web | planned | Flutter web (review surface) |
| iOS | planned | Flutter |
| Android | planned | Flutter |
| watchOS | deferred to v3 | native SwiftUI companion via WatchConnectivity |

## Architecture at a glance

- **Local-first, offline-always.** Drift (SQLite) is the source of truth across all
  platforms. The cloud is a sync target, not a dependency (v2+).
- **MVVM + repository pattern.** View → ViewModel → Repository → Service, dependencies
  pointing inward.
- **Riverpod** for state + dependency injection, **go_router** for navigation.
- **Wall-clock rest timers.** Store an absolute `endsAt` timestamp; compute remaining
  time from `now`. Survives backgrounding, screen-off, and process death. An OS-level
  local notification scheduled at `endsAt` is the reliable "rest done" buzz.
- **Native edges only where the OS demands it:** exact-alarm notification scheduling and
  the watchOS surface. Flutter owns ~95% of the app.

See [`docs/quadrille-architecture.md`](docs/quadrille-architecture.md) for the full plan.

## Project layout (feature-first)

```
lib/
├── core/        # database, timer, notifications, theme, router, DI — depends on no feature
├── features/    # templates, session, timer, history, exercises, settings
│   └── <feature>/{domain,data,presentation}/
└── shared/      # reusable widgets (grid cell, set row, countdown ring)
```

## Build phases

- **v1 — Local single-device daily driver:** Drift schema → Templates → Session logging
  grid → Rest timer (ring + scheduled notification) → read-only History.
- **v2 — Multi-device:** Supabase auth + sync; polished web review surface.
- **v3 — Wrist:** SwiftUI watchOS target + WatchConnectivity bridge.

## Development

Flutter SDK (stable). Codegen via `build_runner` for Drift and freezed.

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
./tool/fetch_web_db_assets.sh   # one-time: sqlite3.wasm + drift_worker.js (web only)
flutter run            # device/simulator/emulator
flutter run -d chrome  # web
```

### Web deployment

The web build is served at **https://quadrille.app** from this server. The
Apache vhost points its DocumentRoot at `build/web` and sets
`Cross-Origin-Opener-Policy`/`Cross-Origin-Embedder-Policy` so Drift's web
backend can use durable OPFS-backed SQLite. To rebuild and publish:

```sh
./tool/deploy_web.sh
```

