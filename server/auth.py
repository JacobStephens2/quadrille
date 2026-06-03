"""First-party email+password auth with opaque server-side sessions.

Sessions are random tokens stored hashed in Postgres. Web clients receive an
httpOnly Secure cookie (same-origin); mobile clients receive the same token in
the response body and send it as a Bearer header. Either way the server looks
up the session row, which gives instant revocation and per-device control.
"""
import os
import re

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from pydantic import BaseModel, EmailStr

from db import db_cursor
from mailer import send_password_reset_email, send_verification_email
from security import hash_password, hash_token, new_opaque_token, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])

BASE_URL = os.environ.get("QUADRILLE_BASE_URL", "https://quadrille.app")
COOKIE_NAME = "__Host-quadrille_session"
COOKIE_MAX_AGE = 60 * 60 * 24 * 180  # 180 days (absolute session lifetime)
MIN_PASSWORD_LEN = 8


# --- models ----------------------------------------------------------------

class RegisterBody(BaseModel):
    email: EmailStr
    password: str
    deviceId: str | None = None
    platform: str | None = None


class LoginBody(BaseModel):
    email: EmailStr
    password: str
    deviceId: str | None = None
    platform: str | None = None


class VerifyBody(BaseModel):
    token: str


class ForgotBody(BaseModel):
    email: EmailStr


class ResetBody(BaseModel):
    token: str
    password: str


# --- helpers ---------------------------------------------------------------

def _rate_limit(key: str, action: str, max_count: int, window_seconds: int) -> bool:
    """Returns False when the caller has exceeded max_count in the window."""
    with db_cursor(commit=True) as cur:
        cur.execute(
            "SELECT count(*) FROM rate_limit_events "
            "WHERE key=%s AND action=%s AND created_at > now() - make_interval(secs => %s)",
            (key, action, window_seconds),
        )
        if cur.fetchone()[0] >= max_count:
            return False
        cur.execute(
            "INSERT INTO rate_limit_events (key, action) VALUES (%s, %s)",
            (key, action),
        )
        return True


def _set_session_cookie(response: Response, token: str) -> None:
    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        max_age=COOKIE_MAX_AGE,
        httponly=True,
        secure=True,
        samesite="lax",
        path="/",
    )


def _create_session(user_id: str, device_id: str | None, platform: str | None) -> str:
    token = new_opaque_token()
    with db_cursor(commit=True) as cur:
        cur.execute(
            "INSERT INTO auth_sessions "
            "(user_id, token_hash, device_id, platform, idle_expires_at, absolute_expires_at) "
            "VALUES (%s, %s, %s, %s, now() + interval '30 days', now() + interval '180 days')",
            (user_id, hash_token(token), device_id, platform),
        )
    return token


def _extract_token(request: Request) -> tuple[str | None, str | None]:
    """Returns (auth_via, token): 'bearer' from the header, else 'cookie'."""
    header = request.headers.get("authorization", "")
    if header.startswith("Bearer "):
        return "bearer", header[7:].strip()
    cookie = request.cookies.get(COOKIE_NAME)
    if cookie:
        return "cookie", cookie
    return None, None


async def current_user(request: Request) -> dict:
    via, token = _extract_token(request)
    if not token:
        raise HTTPException(status_code=401, detail="Not signed in")
    with db_cursor(commit=True, dict_rows=True) as cur:
        cur.execute(
            """
            SELECT s.id AS session_id, s.user_id, u.email, u.email_verified_at, u.disabled_at
            FROM auth_sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = %s
              AND s.revoked_at IS NULL
              AND s.idle_expires_at > now()
              AND s.absolute_expires_at > now()
            """,
            (hash_token(token),),
        )
        row = cur.fetchone()
        if row is None or row["disabled_at"] is not None:
            raise HTTPException(status_code=401, detail="Session invalid or expired")
        # Slide the idle window forward.
        cur.execute(
            "UPDATE auth_sessions SET last_seen_at = now(), "
            "idle_expires_at = now() + interval '30 days' WHERE id = %s",
            (row["session_id"],),
        )
    return {
        "user_id": str(row["user_id"]),
        "email": row["email"],
        "email_verified": row["email_verified_at"] is not None,
        "session_id": str(row["session_id"]),
        "auth_via": via,
    }


async def current_user_mutating(request: Request) -> dict:
    """Like current_user, but enforces an Origin/Referer check for cookie auth
    (CSRF defense). Bearer (mobile) auth is exempt — not cookie-driven."""
    user = await current_user(request)
    if user["auth_via"] == "cookie":
        origin = request.headers.get("origin") or request.headers.get("referer") or ""
        if not origin.startswith(BASE_URL):
            raise HTTPException(status_code=403, detail="Bad origin")
    return user


def _public_user(user_id: str, email: str, email_verified: bool) -> dict:
    return {"id": user_id, "email": email, "emailVerified": email_verified}


# --- endpoints -------------------------------------------------------------

@router.post("/register")
def register(body: RegisterBody, request: Request, response: Response) -> dict:
    ip = request.client.host if request.client else "unknown"
    if not _rate_limit(ip, "register", max_count=10, window_seconds=3600):
        raise HTTPException(status_code=429, detail="Too many attempts")
    if len(body.password) < MIN_PASSWORD_LEN:
        raise HTTPException(
            status_code=400,
            detail=f"Password must be at least {MIN_PASSWORD_LEN} characters",
        )
    email = body.email.lower().strip()
    with db_cursor(commit=True, dict_rows=True) as cur:
        cur.execute("SELECT 1 FROM users WHERE email = %s", (email,))
        if cur.fetchone() is not None:
            raise HTTPException(status_code=409, detail="Email already registered")
        cur.execute(
            "INSERT INTO users (email, password_hash) VALUES (%s, %s) RETURNING id",
            (email, hash_password(body.password)),
        )
        user_id = str(cur.fetchone()["id"])
        verify_token = new_opaque_token()
        cur.execute(
            "INSERT INTO auth_tokens (user_id, purpose, token_hash, expires_at) "
            "VALUES (%s, 'verify_email', %s, now() + interval '24 hours')",
            (user_id, hash_token(verify_token)),
        )
    try:
        send_verification_email(email, verify_token)
    except Exception:
        pass  # don't fail signup on mail hiccup; user can resend
    token = _create_session(user_id, body.deviceId, body.platform)
    _set_session_cookie(response, token)
    return {"token": token, "user": _public_user(user_id, email, False)}


@router.post("/login")
def login(body: LoginBody, request: Request, response: Response) -> dict:
    ip = request.client.host if request.client else "unknown"
    email = body.email.lower().strip()
    if not _rate_limit(f"{ip}:{email}", "login", max_count=10, window_seconds=900):
        raise HTTPException(status_code=429, detail="Too many attempts, try later")
    with db_cursor(dict_rows=True) as cur:
        cur.execute(
            "SELECT id, password_hash, email_verified_at, disabled_at FROM users WHERE email = %s",
            (email,),
        )
        row = cur.fetchone()
    if row is None or row["disabled_at"] is not None or not verify_password(
        row["password_hash"], body.password
    ):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    user_id = str(row["id"])
    token = _create_session(user_id, body.deviceId, body.platform)
    _set_session_cookie(response, token)
    return {
        "token": token,
        "user": _public_user(user_id, email, row["email_verified_at"] is not None),
    }


@router.get("/me")
def me(user: dict = Depends(current_user)) -> dict:
    return {"user": _public_user(user["user_id"], user["email"], user["email_verified"])}


@router.post("/logout")
def logout(response: Response, user: dict = Depends(current_user)) -> dict:
    with db_cursor(commit=True) as cur:
        cur.execute(
            "UPDATE auth_sessions SET revoked_at = now() WHERE id = %s",
            (user["session_id"],),
        )
    response.delete_cookie(COOKIE_NAME, path="/")
    return {"ok": True}


@router.post("/logout-all")
def logout_all(response: Response, user: dict = Depends(current_user)) -> dict:
    with db_cursor(commit=True) as cur:
        cur.execute(
            "UPDATE auth_sessions SET revoked_at = now() "
            "WHERE user_id = %s AND revoked_at IS NULL",
            (user["user_id"],),
        )
    response.delete_cookie(COOKIE_NAME, path="/")
    return {"ok": True}


@router.get("/sessions")
def list_sessions(user: dict = Depends(current_user)) -> dict:
    with db_cursor(dict_rows=True) as cur:
        cur.execute(
            "SELECT id, device_id, platform, created_at, last_seen_at "
            "FROM auth_sessions WHERE user_id = %s AND revoked_at IS NULL "
            "ORDER BY last_seen_at DESC",
            (user["user_id"],),
        )
        rows = cur.fetchall()
    return {
        "sessions": [
            {
                "id": str(r["id"]),
                "deviceId": r["device_id"],
                "platform": r["platform"],
                "current": str(r["id"]) == user["session_id"],
                "lastSeenAt": r["last_seen_at"].isoformat(),
            }
            for r in rows
        ]
    }


@router.post("/email/verify")
def verify_email(body: VerifyBody) -> dict:
    with db_cursor(commit=True, dict_rows=True) as cur:
        cur.execute(
            "SELECT id, user_id FROM auth_tokens "
            "WHERE token_hash = %s AND purpose = 'verify_email' "
            "AND consumed_at IS NULL AND expires_at > now()",
            (hash_token(body.token),),
        )
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=400, detail="Invalid or expired token")
        cur.execute(
            "UPDATE users SET email_verified_at = now(), updated_at = now() WHERE id = %s",
            (row["user_id"],),
        )
        cur.execute(
            "UPDATE auth_tokens SET consumed_at = now() WHERE id = %s", (row["id"],)
        )
    return {"ok": True}


@router.post("/email/resend-verification")
def resend_verification(user: dict = Depends(current_user)) -> dict:
    if user["email_verified"]:
        return {"ok": True}
    if not _rate_limit(user["user_id"], "resend_verify", max_count=5, window_seconds=3600):
        raise HTTPException(status_code=429, detail="Too many requests")
    verify_token = new_opaque_token()
    with db_cursor(commit=True) as cur:
        cur.execute(
            "INSERT INTO auth_tokens (user_id, purpose, token_hash, expires_at) "
            "VALUES (%s, 'verify_email', %s, now() + interval '24 hours')",
            (user["user_id"], hash_token(verify_token)),
        )
    try:
        send_verification_email(user["email"], verify_token)
    except Exception:
        pass
    return {"ok": True}


@router.post("/password/forgot", status_code=202)
def forgot_password(body: ForgotBody, request: Request) -> dict:
    ip = request.client.host if request.client else "unknown"
    email = body.email.lower().strip()
    # Always 202 regardless of existence (no account enumeration).
    if not _rate_limit(f"{ip}:{email}", "forgot", max_count=5, window_seconds=3600):
        return {"ok": True}
    with db_cursor(commit=True, dict_rows=True) as cur:
        cur.execute("SELECT id FROM users WHERE email = %s", (email,))
        row = cur.fetchone()
        if row is not None:
            reset_token = new_opaque_token()
            cur.execute(
                "INSERT INTO auth_tokens (user_id, purpose, token_hash, expires_at) "
                "VALUES (%s, 'password_reset', %s, now() + interval '1 hour')",
                (str(row["id"]), hash_token(reset_token)),
            )
            try:
                send_password_reset_email(email, reset_token)
            except Exception:
                pass
    return {"ok": True}


@router.post("/password/reset")
def reset_password(body: ResetBody) -> dict:
    if len(body.password) < MIN_PASSWORD_LEN:
        raise HTTPException(
            status_code=400,
            detail=f"Password must be at least {MIN_PASSWORD_LEN} characters",
        )
    with db_cursor(commit=True, dict_rows=True) as cur:
        cur.execute(
            "SELECT id, user_id FROM auth_tokens "
            "WHERE token_hash = %s AND purpose = 'password_reset' "
            "AND consumed_at IS NULL AND expires_at > now()",
            (hash_token(body.token),),
        )
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=400, detail="Invalid or expired token")
        cur.execute(
            "UPDATE users SET password_hash = %s, updated_at = now() WHERE id = %s",
            (hash_password(body.password), row["user_id"]),
        )
        cur.execute(
            "UPDATE auth_tokens SET consumed_at = now() WHERE id = %s", (row["id"],)
        )
        # Reset revokes every session.
        cur.execute(
            "UPDATE auth_sessions SET revoked_at = now() "
            "WHERE user_id = %s AND revoked_at IS NULL",
            (row["user_id"],),
        )
    return {"ok": True}
