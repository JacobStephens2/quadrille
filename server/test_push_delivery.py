"""Store and send a Web Push subscription only when the shared check accepts it."""
import importlib
import json
import os
import unittest
from contextlib import contextmanager
from unittest.mock import patch

from fastapi.testclient import TestClient

ENV = {
    "QUADRILLE_SYNC_DB": "unused-in-route-tests",
    "QUADRILLE_SYNC_TOKEN": "test-token",
    "VAPID_PUBLIC_KEY": "test-public",
    "VAPID_PRIVATE_PEM": "test-private",
}

with patch.dict(os.environ, ENV):
    with patch("psycopg2.pool.SimpleConnectionPool"):
        auth = importlib.import_module("auth")
        push = importlib.import_module("push")
        sync_app = importlib.import_module("sync_app")

from push_endpoint import push_request_session

ACCEPTED = "https://fcm.googleapis.com/fcm/send/abc"
REJECTED = "https://127.0.0.1/secret"
LEGACY_AUTH = {"Authorization": "Bearer test-token"}


class _Cursor:
    def __init__(self, queries):
        self.queries = queries

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, sql, params=None):
        self.queries.append((sql, params))


class _Connection:
    def __init__(self, queries):
        self.queries = queries

    def cursor(self):
        return _Cursor(self.queries)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class SubscriptionWriteTest(unittest.TestCase):
    def setUp(self):
        self.app = sync_app.app
        self.app.dependency_overrides[auth.current_user] = lambda: {
            "user_id": "account-a"
        }
        self.client = TestClient(self.app)
        self.addCleanup(self.client.close)
        self.addCleanup(self.app.dependency_overrides.clear)
        self.user_queries = []
        self.legacy_queries = []

        @contextmanager
        def user_cursor(**kwargs):
            yield _Cursor(self.user_queries)

        self.user_cursor = patch.object(push, "db_cursor", user_cursor)
        self.user_cursor.start()
        self.addCleanup(self.user_cursor.stop)

        conn = _Connection(self.legacy_queries)
        pool = sync_app._pool
        self.getconn = patch.object(pool, "getconn", return_value=conn)
        self.putconn = patch.object(pool, "putconn")
        self.getconn.start()
        self.putconn.start()
        self.addCleanup(self.getconn.stop)
        self.addCleanup(self.putconn.stop)

    def test_both_writes_reject_an_endpoint_the_check_rejects(self):
        legacy = self.client.put(
            "/v1/push/subscription",
            headers=LEGACY_AUTH,
            json={"endpoint": REJECTED, "keys": {"p256dh": "k", "auth": "a"}},
        )
        user = self.client.put(
            "/push/subscription",
            json={"endpoint": REJECTED, "keys": {"p256dh": "k", "auth": "a"}},
        )
        self.assertEqual(legacy.status_code, 400)
        self.assertEqual(user.status_code, 400)
        self.assertEqual(legacy.json()["detail"], "Invalid push endpoint")
        self.assertEqual(user.json()["detail"], "Invalid push endpoint")
        self.assertEqual(self.legacy_queries, [])
        self.assertEqual(self.user_queries, [])

    def test_both_writes_store_an_endpoint_the_check_accepts(self):
        body = {"endpoint": ACCEPTED, "keys": {"p256dh": "k", "auth": "a"}}
        legacy = self.client.put(
            "/v1/push/subscription", headers=LEGACY_AUTH, json=body
        )
        user = self.client.put("/push/subscription", json=body)
        self.assertEqual(legacy.status_code, 200)
        self.assertEqual(user.status_code, 200)
        self.assertIn(ACCEPTED, self.legacy_queries[0][1])
        self.assertIn(ACCEPTED, self.user_queries[0][1])


class PushSendTest(unittest.TestCase):
    def test_both_sends_skip_an_endpoint_the_check_rejects(self):
        with self._webpush() as webpush:
            with patch.object(
                sync_app,
                "_get_subscription",
                return_value={"endpoint": REJECTED, "p256dh": "k", "auth": "a"},
            ):
                sync_app._send_push("default", "Rest done", "Up")
            with patch.object(push, "db_cursor", self._rows([REJECTED])):
                push._send_to_user("account-a", "Rest done", "Up")
        webpush.assert_not_called()

    def test_both_sends_set_a_timeout_and_do_not_follow_redirects(self):
        mozilla = "https://updates.push.services.mozilla.com/wpush/v2/abc"
        with self._webpush() as webpush:
            with patch.object(
                sync_app,
                "_get_subscription",
                return_value={"endpoint": ACCEPTED, "p256dh": "k", "auth": "a"},
            ):
                sync_app._send_push("default", "Rest done", "Up")
            with patch.object(push, "db_cursor", self._rows([REJECTED, mozilla])):
                push._send_to_user("account-a", "Rest done", "Up")
        self.assertEqual(webpush.call_count, 2)
        endpoints = [
            call.kwargs["subscription_info"]["endpoint"] for call in webpush.call_args_list
        ]
        self.assertEqual(endpoints, [ACCEPTED, mozilla])
        for call in webpush.call_args_list:
            self.assertEqual(call.kwargs["timeout"], 10)
            self.assertEqual(
                call.kwargs["data"], json.dumps({"title": "Rest done", "body": "Up"})
            )
            self.assertEqual(call.kwargs["vapid_private_key"], "test-private")
            self.assertEqual(
                call.kwargs["vapid_claims"], {"sub": "mailto:admin@quadrille.app"}
            )
            self._assert_session_does_not_follow_redirects(call.kwargs["requests_session"])

    def test_push_request_session_does_not_follow_redirects(self):
        self._assert_session_does_not_follow_redirects(push_request_session())

    @staticmethod
    @contextmanager
    def _webpush():
        with patch("push_endpoint.webpush") as webpush:
            yield webpush

    @staticmethod
    def _rows(endpoints):
        rows = [
            {"endpoint": endpoint, "p256dh": "k", "auth": "a"} for endpoint in endpoints
        ]

        @contextmanager
        def cursor(**kwargs):
            yield _Fetch(rows)

        return cursor

    @staticmethod
    def _assert_session_does_not_follow_redirects(session):
        seen = {}

        def wrapper(self, method, url, *args, **kwargs):
            seen["allow_redirects"] = kwargs.get("allow_redirects")
            return object()

        with patch("requests.Session.request", wrapper):
            session.post(ACCEPTED)
        if seen.get("allow_redirects") is not False:
            raise AssertionError(
                "push session followed redirects: "
                f"allow_redirects={seen.get('allow_redirects')!r}"
            )


class _Fetch:
    def __init__(self, rows):
        self.rows = rows

    def execute(self, sql, params=None):
        return None

    def fetchall(self):
        return self.rows


if __name__ == "__main__":
    unittest.main()
