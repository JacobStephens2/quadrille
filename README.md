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
| Web | live at [quadrille.app](https://quadrille.app) | Flutter web |
| Android | signed APKs on [GitHub Releases](https://github.com/JacobStephens2/quadrille/releases) | Flutter |
| iOS | in progress (App Store signing wired) | Flutter |
| watchOS | in progress | native SwiftUI companion via WatchConnectivity |

## Architecture at a glance

- **Local-first, offline-always.** Drift (SQLite) is the source of truth across all
  platforms. The cloud is a sync target, not a dependency: optional accounts sync
  through a self-hosted FastAPI service (see [`server/`](server/README.md)).
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
- **v2 — Multi-device:** optional accounts (email + password) with per-user row-merge
  sync via the FastAPI service in `server/`; Web Push rest alerts.
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

### Android releases

Start from a clean checkout, fetch and sync master, then bump `version:` in
`pubspec.yaml` (both the version and build number). For example, to release
`1.3.0+5`:

```sh
git fetch origin master
git switch master
git merge --ff-only origin/master
# Set version: 1.3.0+5 in pubspec.yaml, then:
git add pubspec.yaml
git commit -m "Bump version to 1.3.0+5"
git push origin master
git tag v1.3.0
git push origin v1.3.0
```

The release workflow fetches master again and requires the tagged commit to
contain every commit on current `origin/master`. Tags at master or descendants
of master pass; stale or divergent tags fail with `Tag is not based on current
master` before the signing keystore is decoded, so no APK or release is published.
If master advances before the check, fetch and sync again before tagging the
updated commit. The check needs full Git history, which the workflow fetches at
checkout. Manual workflow dry-runs retain their commit-SHA artifact names and
skip this tag guard.

This protection applies to commits containing the updated workflow. GitHub runs
the workflow from the tagged commit, so tags pointing to older commits that
predate the guard still use their historical, unguarded release workflow.

Successful tags publish the signed APK and its SHA-256 checksum on GitHub
Releases. Run the release guard regression tests locally with:

```sh
python3 test/release_guard_test.py
```

## License

Source-available, all rights reserved — published for reference only. See [`LICENSE`](LICENSE).
