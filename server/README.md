# Quadrille account + sync service

A FastAPI service backing **accounts + per-user cloud sync**, mounted behind
Apache at `https://quadrille.app/api/` (same-origin as the web app — no CORS).

Modules: `db.py` (pool + schema), `security.py` (Argon2id + opaque tokens),
`mailer.py` (SMTP, provider-agnostic), `auth.py` (auth router), `sync_user.py`
(per-user sync + account), `sync_app.py` (entrypoint; also keeps the legacy
`/v1/*` shared-token sync + push during transition).

## Auth model

- Email + password (Argon2id). Opaque server-side sessions stored hashed;
  web gets an httpOnly `__Host-quadrille_session` cookie, mobile a Bearer
  token. Sliding 30-day idle + 180-day absolute expiry; revocation on
  logout/logout-all/password-reset. Cookie mutations require a matching
  `Origin` (CSRF). Cloud sync requires a verified email.
- Endpoints: `/auth/{register,login,logout,logout-all,me,sessions,
  email/verify,email/resend-verification,password/forgot,password/reset}`,
  `/sync` (GET/PUT, server-side row-merge LWW + tombstones), `/account/export`,
  `DELETE /account`, `/v1/version`.

## Email (Resend)

Verification + reset email goes out over **Resend** via the provider-agnostic
SMTP mailer: `SMTP_HOST=smtp.resend.com`, `SMTP_USER=resend`,
`SMTP_PASS=<resend key>`, `SMTP_FROM_EMAIL=quadrille@stephens.page` (reuses the
stephens.page Resend key shared with other apps; stephens.page is a verified
sending domain). Switch providers by changing env only — no code change.

## Legacy (transition)

The earlier single-account, shared-token sync (`/v1/state`) and push
(`/v1/push/*`) still run. Web Push currently authenticates with that shared
token, so per-account Web Push is pending a Phase-5 migration to session auth.

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
