"""Quadrille cloud-sync service.

A deliberately small, single-account sync backend: it stores one JSON blob (the
same versioned payload the in-app backup produces) per account, with a
monotonic revision and last-write-wins semantics. Auth is a single bearer token
shared across the user's devices. Mounted behind Apache at quadrille.app/api/
(same-origin as the web app, so no CORS needed).

Env (see server/.env, loaded by the systemd unit):
  QUADRILLE_SYNC_DB     postgresql://user:pw@host/db
  QUADRILLE_SYNC_TOKEN  shared bearer token
  QUADRILLE_SYNC_PORT   port to bind (uvicorn, localhost)
"""
import asyncio
import json
import os
import time

import psycopg2
import psycopg2.extras
from psycopg2.pool import SimpleConnectionPool
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel
from pywebpush import WebPushException, webpush

DB_URL = os.environ["QUADRILLE_SYNC_DB"]
TOKEN = os.environ["QUADRILLE_SYNC_TOKEN"]
ACCOUNT = "default"  # single-user; the token namespaces access

# Web Push (VAPID) config — optional; push endpoints 503 if unset.
VAPID_PUBLIC_KEY = os.environ.get("VAPID_PUBLIC_KEY", "")
VAPID_PRIVATE_PEM = os.environ.get("VAPID_PRIVATE_PEM", "")
VAPID_SUB = os.environ.get("VAPID_SUB", "mailto:admin@quadrille.app")

# account -> pending asyncio task that fires the rest-complete push.
_scheduled: "dict[str, asyncio.Task]" = {}

_pool = SimpleConnectionPool(1, 4, dsn=DB_URL)

app = FastAPI(title="Quadrille Sync", docs_url=None, redoc_url=None)


def _init_db() -> None:
    conn = _pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS sync_state (
                    account     TEXT PRIMARY KEY,
                    payload     JSONB NOT NULL,
                    revision    BIGINT NOT NULL DEFAULT 0,
                    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS push_subscriptions (
                    account     TEXT PRIMARY KEY,
                    endpoint    TEXT NOT NULL,
                    p256dh      TEXT NOT NULL,
                    auth        TEXT NOT NULL,
                    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )
    finally:
        _pool.putconn(conn)


_init_db()


def require_token(authorization: str = Header(default="")) -> None:
    expected = f"Bearer {TOKEN}"
    # Constant-time-ish comparison.
    if len(authorization) != len(expected) or authorization != expected:
        raise HTTPException(status_code=401, detail="Invalid or missing token")


class PushBody(BaseModel):
    payload: dict


@app.get("/v1/health")
def health() -> dict:
    return {"ok": True}


@app.get("/v1/state", dependencies=[Depends(require_token)])
def get_state() -> dict:
    conn = _pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT payload, revision, updated_at FROM sync_state WHERE account = %s",
                (ACCOUNT,),
            )
            row = cur.fetchone()
    finally:
        _pool.putconn(conn)
    if row is None:
        return {"exists": False, "revision": 0, "payload": None}
    payload, revision, updated_at = row
    return {
        "exists": True,
        "revision": revision,
        "updatedAt": updated_at.isoformat(),
        "payload": payload,
    }


@app.put("/v1/state", dependencies=[Depends(require_token)])
def put_state(body: PushBody) -> dict:
    conn = _pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO sync_state (account, payload, revision, updated_at)
                VALUES (%s, %s, 1, now())
                ON CONFLICT (account) DO UPDATE
                  SET payload = EXCLUDED.payload,
                      revision = sync_state.revision + 1,
                      updated_at = now()
                RETURNING revision, updated_at
                """,
                (ACCOUNT, psycopg2.extras.Json(body.payload)),
            )
            revision, updated_at = cur.fetchone()
    finally:
        _pool.putconn(conn)
    return {"revision": revision, "updatedAt": updated_at.isoformat()}


# --- Web Push --------------------------------------------------------------

class Subscription(BaseModel):
    endpoint: str
    keys: dict  # {p256dh, auth}


class ScheduleBody(BaseModel):
    timestamp: int  # epoch milliseconds of the rest deadline
    title: str
    body: str


def _require_vapid() -> None:
    if not VAPID_PUBLIC_KEY or not VAPID_PRIVATE_PEM:
        raise HTTPException(status_code=503, detail="Push not configured")


@app.get("/v1/push/key", dependencies=[Depends(require_token)])
def push_key() -> dict:
    _require_vapid()
    return {"key": VAPID_PUBLIC_KEY}


@app.put("/v1/push/subscription", dependencies=[Depends(require_token)])
def put_subscription(sub: Subscription) -> dict:
    _require_vapid()
    conn = _pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO push_subscriptions (account, endpoint, p256dh, auth, updated_at)
                VALUES (%s, %s, %s, %s, now())
                ON CONFLICT (account) DO UPDATE
                  SET endpoint = EXCLUDED.endpoint,
                      p256dh = EXCLUDED.p256dh,
                      auth = EXCLUDED.auth,
                      updated_at = now()
                """,
                (ACCOUNT, sub.endpoint, sub.keys.get("p256dh"), sub.keys.get("auth")),
            )
    finally:
        _pool.putconn(conn)
    return {"ok": True}


@app.post("/v1/push/schedule", dependencies=[Depends(require_token)])
async def schedule_push(body: ScheduleBody) -> dict:
    _require_vapid()
    delay = max(0.0, body.timestamp / 1000.0 - time.time())
    _cancel_scheduled(ACCOUNT)
    _scheduled[ACCOUNT] = asyncio.create_task(
        _fire_after(delay, ACCOUNT, body.title, body.body)
    )
    return {"ok": True, "delaySeconds": delay}


@app.post("/v1/push/cancel", dependencies=[Depends(require_token)])
async def cancel_push() -> dict:
    _cancel_scheduled(ACCOUNT)
    return {"ok": True}


def _cancel_scheduled(account: str) -> None:
    task = _scheduled.pop(account, None)
    if task is not None and not task.done():
        task.cancel()


async def _fire_after(delay: float, account: str, title: str, body: str) -> None:
    try:
        await asyncio.sleep(delay)
    except asyncio.CancelledError:
        return
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, _send_push, account, title, body)
    _scheduled.pop(account, None)


def _send_push(account: str, title: str, body: str) -> None:
    sub = _get_subscription(account)
    if sub is None:
        return
    try:
        webpush(
            subscription_info={
                "endpoint": sub["endpoint"],
                "keys": {"p256dh": sub["p256dh"], "auth": sub["auth"]},
            },
            data=json.dumps({"title": title, "body": body}),
            vapid_private_key=VAPID_PRIVATE_PEM,
            vapid_claims={"sub": VAPID_SUB},
        )
    except WebPushException as exc:
        # Subscription expired/invalid — drop it so we stop trying.
        status = getattr(exc.response, "status_code", None)
        if status in (404, 410):
            _delete_subscription(account)
    except Exception:
        # Network/other failure — best-effort; don't crash the scheduler task.
        pass


def _get_subscription(account: str):
    conn = _pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT endpoint, p256dh, auth FROM push_subscriptions WHERE account = %s",
                (account,),
            )
            row = cur.fetchone()
    finally:
        _pool.putconn(conn)
    if row is None:
        return None
    return {"endpoint": row[0], "p256dh": row[1], "auth": row[2]}


def _delete_subscription(account: str) -> None:
    conn = _pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("DELETE FROM push_subscriptions WHERE account = %s", (account,))
    finally:
        _pool.putconn(conn)
