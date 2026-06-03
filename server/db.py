"""Shared Postgres connection pool + schema bootstrap for the sync service."""
import os
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
from psycopg2.pool import SimpleConnectionPool

DB_URL = os.environ["QUADRILLE_SYNC_DB"]

_pool = SimpleConnectionPool(1, 8, dsn=DB_URL)


@contextmanager
def db_cursor(commit: bool = False, dict_rows: bool = False):
    conn = _pool.getconn()
    cur = conn.cursor(
        cursor_factory=psycopg2.extras.RealDictCursor if dict_rows else None
    )
    try:
        yield cur
        if commit:
            conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        _pool.putconn(conn)


def init_db() -> None:
    """Creates all tables (idempotent). Legacy sync_state/push_subscriptions
    are kept alongside the new per-user tables during the transition."""
    with db_cursor(commit=True) as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
        cur.execute("CREATE EXTENSION IF NOT EXISTS citext")

        # --- legacy single-account sync (kept during transition) ---
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                account TEXT PRIMARY KEY,
                payload JSONB NOT NULL,
                revision BIGINT NOT NULL DEFAULT 0,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS push_subscriptions (
                account TEXT PRIMARY KEY,
                endpoint TEXT NOT NULL,
                p256dh TEXT NOT NULL,
                auth TEXT NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )

        # --- accounts ---
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                email CITEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                email_verified_at TIMESTAMPTZ,
                disabled_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS auth_sessions (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                token_hash TEXT NOT NULL UNIQUE,
                device_id TEXT,
                platform TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                idle_expires_at TIMESTAMPTZ NOT NULL,
                absolute_expires_at TIMESTAMPTZ NOT NULL,
                revoked_at TIMESTAMPTZ
            )
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS auth_sessions_user_idx ON auth_sessions(user_id)"
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS auth_tokens (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                purpose TEXT NOT NULL CHECK (purpose IN ('verify_email','password_reset')),
                token_hash TEXT NOT NULL UNIQUE,
                expires_at TIMESTAMPTZ NOT NULL,
                consumed_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS user_sync_state (
                user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                payload JSONB NOT NULL,
                revision BIGINT NOT NULL DEFAULT 0,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS user_push_subscriptions (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                device_id TEXT,
                endpoint TEXT NOT NULL UNIQUE,
                p256dh TEXT NOT NULL,
                auth TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS user_push_user_idx ON user_push_subscriptions(user_id)"
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS rate_limit_events (
                id BIGSERIAL PRIMARY KEY,
                key TEXT NOT NULL,
                action TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS rate_limit_idx ON rate_limit_events(key, action, created_at)"
        )
