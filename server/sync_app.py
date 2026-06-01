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
import os

import psycopg2
import psycopg2.extras
from psycopg2.pool import SimpleConnectionPool
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

DB_URL = os.environ["QUADRILLE_SYNC_DB"]
TOKEN = os.environ["QUADRILLE_SYNC_TOKEN"]
ACCOUNT = "default"  # single-user; the token namespaces access

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
