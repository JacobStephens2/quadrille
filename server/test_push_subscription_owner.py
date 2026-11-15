"""Who may write a stored Web Push subscription through PUT /push/subscription.

The rule lives in the subscription upsert, so these tests run the route
against a throwaway Postgres cluster with the production schema. They skip
when no Postgres server binaries are installed.
"""
import glob
import importlib
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from psycopg2.pool import SimpleConnectionPool

ENV = {
    "QUADRILLE_SYNC_DB": "unused-in-route-tests",
    "VAPID_PUBLIC_KEY": "test-public",
    "VAPID_PRIVATE_PEM": "test-private",
}

# db creates a pool on import. Prevent that; the tests supply their own.
with patch.dict(os.environ, ENV):
    with patch("psycopg2.pool.SimpleConnectionPool"):
        auth = importlib.import_module("auth")
        db = importlib.import_module("db")
        push = importlib.import_module("push")

ENDPOINT = "https://fcm.googleapis.com/fcm/send/owned"


def _postgres_bindir():
    """The directory holding initdb and pg_ctl, or None."""
    initdb = shutil.which("initdb")
    if initdb is None:
        # Debian and Ubuntu keep the server binaries off PATH.
        initdb = next(iter(glob.glob("/usr/lib/postgresql/*/bin/initdb")), None)
    return None if initdb is None else os.path.dirname(initdb)


class SubscriptionOwnerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bindir = _postgres_bindir()
        if bindir is None:
            raise unittest.SkipTest("no Postgres server binaries (initdb, pg_ctl)")
        root = tempfile.mkdtemp(prefix="quadrille-pg-")
        cls.addClassCleanup(shutil.rmtree, root)
        data = os.path.join(root, "data")
        pg_ctl = os.path.join(bindir, "pg_ctl")
        subprocess.run(
            [os.path.join(bindir, "initdb"), "-D", data, "-U", "postgres",
             "-A", "trust", "--no-sync"],
            check=True, capture_output=True,
        )
        # Socket only, inside root: no TCP port to collide with.
        subprocess.run(
            [pg_ctl, "-D", data, "-l", os.path.join(root, "server.log"), "-w",
             "-o", f"-c listen_addresses='' -k {shlex.quote(root)} -c fsync=off",
             "start"],
            check=True, capture_output=True,
        )
        cls.addClassCleanup(
            subprocess.run,
            [pg_ctl, "-D", data, "-m", "immediate", "-w", "stop"],
            check=True, capture_output=True,
        )
        pool = SimpleConnectionPool(1, 2, host=root, dbname="postgres", user="postgres")
        cls.addClassCleanup(pool.closeall)
        pool_patch = patch.object(db, "_pool", pool)
        pool_patch.start()
        cls.addClassCleanup(pool_patch.stop)
        db.init_db()

    def setUp(self):
        with db.db_cursor(commit=True) as cur:
            cur.execute("TRUNCATE users CASCADE")
        self.owner = self._account("owner@example.test")
        self.caller = self._account("caller@example.test")
        self.app = FastAPI()
        self.app.include_router(push.router)
        self.client = TestClient(self.app)
        self.addCleanup(self.client.close)

    @staticmethod
    def _account(email):
        with db.db_cursor(commit=True) as cur:
            cur.execute(
                "INSERT INTO users (email, password_hash) VALUES (%s, 'unused') RETURNING id",
                (email,),
            )
            return str(cur.fetchone()[0])

    def put(self, account, p256dh, auth_key, device_id):
        self.app.dependency_overrides[auth.current_user] = lambda: {"user_id": account}
        return self.client.put(
            "/push/subscription",
            json={
                "endpoint": ENDPOINT,
                "keys": {"p256dh": p256dh, "auth": auth_key},
                "deviceId": device_id,
            },
        )

    def stored(self):
        with db.db_cursor(dict_rows=True) as cur:
            cur.execute(
                "SELECT user_id::text AS user_id, device_id, p256dh, auth, "
                "created_at, last_seen_at FROM user_push_subscriptions WHERE endpoint = %s",
                (ENDPOINT,),
            )
            return cur.fetchone()

    def store_for_owner(self):
        response = self.put(self.owner, "owner-p256dh", "owner-auth", "owner-phone")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.stored()["user_id"], self.owner)

    def test_another_account_with_the_stored_keys_moves_the_row_to_itself(self):
        self.store_for_owner()
        response = self.put(self.caller, "owner-p256dh", "owner-auth", "caller-laptop")
        self.assertEqual(response.status_code, 200)
        row = self.stored()
        self.assertEqual(
            (row["user_id"], row["device_id"], row["p256dh"], row["auth"]),
            (self.caller, "caller-laptop", "owner-p256dh", "owner-auth"),
        )

    def test_owning_account_refreshes_its_own_row(self):
        self.store_for_owner()
        response = self.put(self.owner, "new-p256dh", "new-auth", "owner-tablet")
        self.assertEqual(response.status_code, 200)
        row = self.stored()
        self.assertEqual(
            (row["user_id"], row["device_id"], row["p256dh"], row["auth"]),
            (self.owner, "owner-tablet", "new-p256dh", "new-auth"),
        )

    def test_another_account_without_the_stored_keys_gets_409_and_the_row_is_unchanged(self):
        self.store_for_owner()
        before = self.stored()
        for p256dh, auth_key in (
            ("caller-p256dh", "caller-auth"),
            ("owner-p256dh", "caller-auth"),
            ("caller-p256dh", "owner-auth"),
        ):
            with self.subTest(p256dh=p256dh, auth=auth_key):
                response = self.put(self.caller, p256dh, auth_key, "caller-laptop")
                self.assertEqual(response.status_code, 409)
                self.assertEqual(self.stored(), before)


if __name__ == "__main__":
    unittest.main()
