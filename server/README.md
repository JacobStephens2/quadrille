# Quadrille sync service

A small FastAPI service backing **v2 cloud sync**. Single-account, token-gated;
stores one JSON blob (the same payload as the in-app backup) with a monotonic
revision and last-write-wins semantics. Mounted behind Apache at
`https://quadrille.app/api/` (same-origin as the web app — no CORS).

## Endpoints

- `GET  /v1/health` → `{ok: true}`
- `GET  /v1/state`  (Bearer token) → `{exists, revision, updatedAt?, payload?}`
- `PUT  /v1/state`  (Bearer token, body `{payload: {...}}`) → `{revision, updatedAt}`

## Deployment (this VPS)

- **Postgres**: role `quadrille`, db `quadrille_sync` (cluster on the volume).
- **Env**: `server/.env` (gitignored) holds `QUADRILLE_SYNC_DB`,
  `QUADRILLE_SYNC_TOKEN`, `QUADRILLE_SYNC_PORT=3475`.
- **venv**: `/mnt/volume_nyc3_01/jacob/quadrille-sync-venv` (fastapi, uvicorn,
  psycopg2-binary) — on the volume to spare the root disk.
- **systemd**: `quadrille-sync.service` runs
  `uvicorn sync_app:app --host 127.0.0.1 --port 3475`.
  Manage with `sudo systemctl restart quadrille-sync`.
- **Apache**: `quadrille.app-le-ssl.conf` has
  `ProxyPass /api/ http://127.0.0.1:3475/`.

## Client setup

In the app: Settings → Cloud sync → Set up sync → paste the
`QUADRILLE_SYNC_TOKEN`. The server URL defaults to `https://quadrille.app/api`.
Use **Upload** to push this device's data and **Download** to replace this
device with the cloud copy.
