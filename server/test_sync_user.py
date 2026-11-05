"""Route contract tests; no production pool, credentials, or database."""
import importlib
import os
import unittest
from contextlib import contextmanager
from datetime import datetime, timezone
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

# db creates a pool on import. Prevent that before importing either router.
with patch.dict(os.environ, {"QUADRILLE_SYNC_DB": "unused-in-route-tests"}):
    with patch("psycopg2.pool.SimpleConnectionPool"):
        sync_user = importlib.import_module("sync_user")
        auth = importlib.import_module("auth")


class SyncRoutesTest(unittest.TestCase):
    def setUp(self):
        self.app = FastAPI()
        self.app.include_router(sync_user.router)
        self.user = {
            "user_id": "account-a", "email_verified": True, "auth_via": "bearer"
        }
        self.app.dependency_overrides[auth.current_user] = lambda: self.user
        self.app.dependency_overrides[auth.current_user_mutating] = lambda: self.user
        self.client = TestClient(self.app)
        self.queries = []
        self.persistence_opens = 0
        self.rows = []
        self.cursor_patch = patch.object(sync_user, "db_cursor", self.cursor)
        self.cursor_patch.start()
        self.addCleanup(self.cursor_patch.stop)
        self.addCleanup(self.client.close)

    @contextmanager
    def cursor(self, **kwargs):
        self.persistence_opens += 1
        yield self

    def execute(self, sql, params):
        self.queries.append((sql, params))

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None

    def request(self, method, expected):
        headers = {} if expected is None else {"X-Quadrille-Expected-Account": expected}
        if method == "GET":
            return self.client.get("/sync", headers=headers)
        return self.client.put("/sync", headers=headers, json={"payload": {"tables": {}}})

    def test_mismatch_rejects_both_routes_before_workout_persistence(self):
        for method in ("GET", "PUT"):
            with self.subTest(method=method):
                result = self.request(method, "account-b")
                self.assertEqual(result.status_code, 409)
                self.assertEqual(result.json()["detail"], "Account changed. Please try again.")
        self.assertEqual(self.persistence_opens, 0)

    def test_matching_and_legacy_requests_use_authenticated_account(self):
        for expected in ("account-a", None):
            for method in ("GET", "PUT"):
                with self.subTest(method=method, expected=expected):
                    self.queries.clear()
                    self.rows = [None]
                    if method == "PUT":
                        self.rows.append({"revision": 1, "updated_at": datetime.now(timezone.utc)})
                    result = self.request(method, expected)
                    self.assertEqual(result.status_code, 200)
                    self.assertEqual(self.queries[0][1], ("account-a",))
                    if method == "PUT":
                        self.assertEqual(self.queries[1][1][0], "account-a")
                    else:
                        self.assertFalse(result.json()["exists"])

    def test_verification_still_precedes_account_assertion(self):
        self.user["email_verified"] = False
        for method in ("GET", "PUT"):
            self.assertEqual(self.request(method, "account-b").status_code, 403)
        self.assertEqual(self.persistence_opens, 0)

    def test_missing_auth_is_still_rejected(self):
        self.app.dependency_overrides.clear()
        for method in ("GET", "PUT"):
            self.assertEqual(self.request(method, "account-a").status_code, 401)
        self.assertEqual(self.persistence_opens, 0)

    def test_cookie_origin_check_still_precedes_account_assertion(self):
        self.app.dependency_overrides.pop(auth.current_user_mutating)
        self.user["auth_via"] = "cookie"
        with patch.object(auth, "current_user", return_value=self.user):
            self.assertEqual(self.request("PUT", "account-b").status_code, 403)
        self.assertEqual(self.persistence_opens, 0)


if __name__ == "__main__":
    unittest.main()
