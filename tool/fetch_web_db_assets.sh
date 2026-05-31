#!/usr/bin/env bash
# Fetches the two binary assets Drift needs for its web (WASM) backend into
# web/. They are version-locked to the drift / sqlite3 packages in pubspec.lock
# and are NOT committed (binaries) — run this after `flutter pub get` and
# whenever those versions change. CI must run it before `flutter build web`.
set -euo pipefail

cd "$(dirname "$0")/.."

ver() { awk "/^  $1:/{f=1} f&&/version:/{gsub(/[\" ]/,\"\"); split(\$0,a,\":\"); print a[2]; exit}" pubspec.lock; }

DRIFT_VERSION="$(ver drift)"
SQLITE3_VERSION="$(ver sqlite3)"

echo "drift   = ${DRIFT_VERSION}"
echo "sqlite3 = ${SQLITE3_VERSION}"

mkdir -p web
curl -fsSL -o web/drift_worker.js \
  "https://github.com/simolus3/drift/releases/download/drift-${DRIFT_VERSION}/drift_worker.js"
curl -fsSL -o web/sqlite3.wasm \
  "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_VERSION}/sqlite3.wasm"

echo "Fetched:"
ls -la web/drift_worker.js web/sqlite3.wasm
