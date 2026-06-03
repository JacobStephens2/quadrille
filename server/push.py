"""Per-account Web Push: subscriptions + deadline scheduling, keyed by user.

Replaces the legacy shared-token push. Auth comes from the account session
(cookie on web / Bearer on mobile). Schedules an asyncio task that fires a
pywebpush notification at the rest deadline to all of the user's subscriptions.
Single uvicorn worker, in-memory — lost on restart, fine for short rests.
"""
import asyncio
import json
import os
import time

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from pywebpush import WebPushException, webpush

from auth import current_user
from db import db_cursor

router = APIRouter(prefix="/push", tags=["push"])

VAPID_PUBLIC_KEY = os.environ.get("VAPID_PUBLIC_KEY", "")
VAPID_PRIVATE_PEM = os.environ.get("VAPID_PRIVATE_PEM", "")
VAPID_SUB = os.environ.get("VAPID_SUB", "mailto:admin@quadrille.app")

# user_id -> pending rest-complete task.
_scheduled: "dict[str, asyncio.Task]" = {}


class Subscription(BaseModel):
    endpoint: str
    keys: dict
    deviceId: str | None = None


class ScheduleBody(BaseModel):
    timestamp: int  # epoch ms of the rest deadline
    title: str
    body: str


def _require_vapid() -> None:
    if not VAPID_PUBLIC_KEY or not VAPID_PRIVATE_PEM:
        raise HTTPException(status_code=503, detail="Push not configured")


@router.get("/key")
def push_key(user: dict = Depends(current_user)) -> dict:
    _require_vapid()
    return {"key": VAPID_PUBLIC_KEY}


@router.put("/subscription")
def put_subscription(
    sub: Subscription, user: dict = Depends(current_user)
) -> dict:
    _require_vapid()
    with db_cursor(commit=True) as cur:
        cur.execute(
            """
            INSERT INTO user_push_subscriptions (user_id, device_id, endpoint, p256dh, auth)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (endpoint) DO UPDATE
              SET user_id = EXCLUDED.user_id,
                  device_id = EXCLUDED.device_id,
                  p256dh = EXCLUDED.p256dh,
                  auth = EXCLUDED.auth,
                  last_seen_at = now()
            """,
            (user["user_id"], sub.deviceId, sub.endpoint,
             sub.keys.get("p256dh"), sub.keys.get("auth")),
        )
    return {"ok": True}


@router.post("/schedule")
async def schedule_push(
    body: ScheduleBody, user: dict = Depends(current_user)
) -> dict:
    _require_vapid()
    uid = user["user_id"]
    delay = max(0.0, body.timestamp / 1000.0 - time.time())
    _cancel_scheduled(uid)
    _scheduled[uid] = asyncio.create_task(
        _fire_after(delay, uid, body.title, body.body)
    )
    return {"ok": True, "delaySeconds": delay}


@router.post("/cancel")
async def cancel_push(user: dict = Depends(current_user)) -> dict:
    _cancel_scheduled(user["user_id"])
    return {"ok": True}


def _cancel_scheduled(uid: str) -> None:
    task = _scheduled.pop(uid, None)
    if task is not None and not task.done():
        task.cancel()


async def _fire_after(delay: float, uid: str, title: str, body: str) -> None:
    try:
        await asyncio.sleep(delay)
    except asyncio.CancelledError:
        return
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, _send_to_user, uid, title, body)
    _scheduled.pop(uid, None)


def _send_to_user(uid: str, title: str, body: str) -> None:
    with db_cursor(dict_rows=True) as cur:
        cur.execute(
            "SELECT endpoint, p256dh, auth FROM user_push_subscriptions WHERE user_id = %s",
            (uid,),
        )
        subs = cur.fetchall()
    for sub in subs:
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
            if getattr(exc.response, "status_code", None) in (404, 410):
                with db_cursor(commit=True) as cur:
                    cur.execute(
                        "DELETE FROM user_push_subscriptions WHERE endpoint = %s",
                        (sub["endpoint"],),
                    )
        except Exception:
            pass
