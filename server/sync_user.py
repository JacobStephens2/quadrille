"""Per-user cloud sync + account endpoints (require a signed-in, verified user).

Sync is whole-snapshot transport but the server MERGES rows by (table, id)
using last-write-wins on max(updatedAt, deletedAt) — so two devices that both
finished workouts no longer overwrite each other, and deletes propagate via
`deletedAt` tombstones (payload v2)."""
import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from auth import current_user, current_user_mutating
from db import db_cursor

router = APIRouter(tags=["sync"])


class SyncBody(BaseModel):
    payload: dict


def _row_timestamp(row: dict) -> int:
    """Effective last-modified for LWW: the later of updatedAt / deletedAt."""
    best = 0
    for key in ("updatedAt", "deletedAt"):
        value = row.get(key)
        if isinstance(value, (int, float)):
            best = max(best, int(value))
    return best


def merge_payloads(existing: dict | None, incoming: dict) -> dict:
    """Row-level last-write-wins union of two v2 payloads. Tombstoned
    (deletedAt) rows are retained so deletions propagate to other devices."""
    ex_tables = (existing or {}).get("tables", {})
    in_tables = incoming.get("tables", {})
    merged: dict[str, list] = {}
    for name in set(ex_tables) | set(in_tables):
        by_id: dict[str, dict] = {}
        for row in ex_tables.get(name, []):
            rid = row.get("id")
            if rid is not None:
                by_id[rid] = row
        for row in in_tables.get(name, []):
            rid = row.get("id")
            if rid is None:
                continue
            current = by_id.get(rid)
            if current is None or _row_timestamp(row) >= _row_timestamp(current):
                by_id[rid] = row
        merged[name] = list(by_id.values())
    return {"format": "quadrille.backup", "version": 2, "tables": merged}


def _require_verified(user: dict) -> None:
    if not user["email_verified"]:
        raise HTTPException(
            status_code=403, detail="Verify your email to enable cloud sync"
        )


@router.get("/sync")
def get_sync(user: dict = Depends(current_user)) -> dict:
    _require_verified(user)
    with db_cursor(dict_rows=True) as cur:
        cur.execute(
            "SELECT payload, revision, updated_at FROM user_sync_state WHERE user_id = %s",
            (user["user_id"],),
        )
        row = cur.fetchone()
    if row is None:
        return {"exists": False, "revision": 0, "payload": None}
    return {
        "exists": True,
        "revision": row["revision"],
        "updatedAt": row["updated_at"].isoformat(),
        "payload": row["payload"],
    }


@router.put("/sync")
def put_sync(body: SyncBody, user: dict = Depends(current_user_mutating)) -> dict:
    _require_verified(user)
    with db_cursor(commit=True, dict_rows=True) as cur:
        cur.execute(
            "SELECT payload, revision FROM user_sync_state WHERE user_id = %s FOR UPDATE",
            (user["user_id"],),
        )
        row = cur.fetchone()
        existing = row["payload"] if row else None
        merged = merge_payloads(existing, body.payload)
        if row is None:
            cur.execute(
                "INSERT INTO user_sync_state (user_id, payload, revision) "
                "VALUES (%s, %s, 1) RETURNING revision, updated_at",
                (user["user_id"], json.dumps(merged)),
            )
        else:
            cur.execute(
                "UPDATE user_sync_state SET payload = %s, revision = revision + 1, "
                "updated_at = now() WHERE user_id = %s RETURNING revision, updated_at",
                (json.dumps(merged), user["user_id"]),
            )
        result = cur.fetchone()
    return {
        "revision": result["revision"],
        "updatedAt": result["updated_at"].isoformat(),
        "payload": merged,
    }


@router.get("/account/export")
def export_account(user: dict = Depends(current_user)) -> dict:
    with db_cursor(dict_rows=True) as cur:
        cur.execute(
            "SELECT payload FROM user_sync_state WHERE user_id = %s",
            (user["user_id"],),
        )
        row = cur.fetchone()
    return {
        "email": user["email"],
        "payload": row["payload"] if row else None,
    }


@router.delete("/account")
def delete_account(user: dict = Depends(current_user_mutating)) -> dict:
    # Cascades to sessions, tokens, sync state, push subscriptions.
    with db_cursor(commit=True) as cur:
        cur.execute("DELETE FROM users WHERE id = %s", (user["user_id"],))
    return {"ok": True}
