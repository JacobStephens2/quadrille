#!/usr/bin/env bash
# Builds the Flutter web release and serves it at https://quadrille.app.
#
# The Apache vhost (quadrille.app-le-ssl.conf) points its DocumentRoot directly
# at build/web, so "deploy" is simply a release build — no copy step. The vhost
# sets COOP/COEP so Drift's web backend gets durable OPFS storage.
set -euo pipefail

cd "$(dirname "$0")/.."

# Web DB binaries are gitignored; ensure they're present before building.
if [[ ! -f web/sqlite3.wasm || ! -f web/drift_worker.js ]]; then
  ./tool/fetch_web_db_assets.sh
fi

flutter build web --release

echo "Built build/web — live at https://quadrille.app"
