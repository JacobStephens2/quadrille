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

## Account sync contract and rollout

Updated clients send `X-Quadrille-Expected-Account: <account id>` on both
`GET /sync` and `PUT /sync`, alongside the captured mobile Bearer token or
the web session cookie. The header is a consistency assertion, not an
authentication credential. After existing authentication, verification, and
cookie-origin checks, both routes compare it with the authenticated account
and return HTTP 409 with `Account changed. Please try again.` on mismatch,
before opening workout sync persistence. Requests without the header retain
legacy behavior for installed older clients.

Deploy this server guard **before** releasing updated clients. A client cannot
retract a request already submitted, and a web cookie may change while a
request body is being prepared. The server guard ensures that a captured
account's payload cannot be applied to a different authenticated account.
No database migration is required.

Account sync captures one verified account, matching Local profile, credential,
database, and generation before waiting. Commands run in invocation order
within that generation; sign-in's pull-merge-push is one command. Auth
transitions, profile/database replacement, and disposal invalidate old work.
A replacement generation can proceed independently of an old stalled request.
Already-started local transactions may finish on their original database;
obsolete responses cannot authorize a following merge, upload, or status write.

In Settings, sign in and verify your email to enable Account sync. **Upload**
pushes this Local profile's workout rows; **Download** merges newer cloud rows
and tombstones, preserving unsynced local edits. Manual actions ignore
Auto-sync. Launch pull and workout-finish push respect Auto-sync; verified
sign-in reconciles even when it is off, including upload to an empty cloud.
Automatic actions are best effort. Superseded manual actions show no success,
empty-cloud, or stale error message. Full backup/restore remains a separate
local operation that includes device settings.

## Route tests

With the server dependencies and `httpx` installed in a test environment:

```sh
python -m unittest discover -s server -p 'test_*.py' -v
```

The harness suppresses the import-time connection pool, supplies authenticated
test users, and substitutes a cursor. It needs no live database or credentials.
