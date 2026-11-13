"""Regression tests for the shared Web Push endpoint check."""
import unittest

from push_endpoint import accepts_push_endpoint


class PushEndpointCheckTest(unittest.TestCase):
    def test_accepts_https_push_service_host(self):
        accepted = (
            "https://fcm.googleapis.com/fcm/send/abc",
            "https://android.googleapis.com/gcm/send/abc",
            "https://jmt17.google.com/abc",
            "https://updates.push.services.mozilla.com/wpush/v2/abc",
            "https://updates-autopush.stage.mozaws.net/wpush/v2/abc",
            "https://updates-autopush.dev.mozaws.net/wpush/v2/abc",
            "https://web.push.apple.com/abc",
            "https://a.b.push.apple.com/abc",
            "https://wns2-am3p.notify.windows.com/abc",
            "https://FCM.googleapis.com/fcm/send/abc",
            "https://fcm.googleapis.com./fcm/send/abc",
        )
        for endpoint in accepted:
            with self.subTest(endpoint=endpoint):
                self.assertTrue(accepts_push_endpoint(endpoint))

    def test_rejects_endpoint_that_is_not_https(self):
        for endpoint in (
            "http://fcm.googleapis.com/fcm/send/abc",
            "ftp://fcm.googleapis.com/fcm/send/abc",
            "https://",
            "",
            None,
        ):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(accepts_push_endpoint(endpoint))

    def test_rejects_address_literal(self):
        for endpoint in (
            "https://127.0.0.1/secret",
            "https://[::1]/secret",
            "https://[::ffff:169.254.169.254]/latest",
        ):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(accepts_push_endpoint(endpoint))

    def test_rejects_host_that_is_not_a_push_service(self):
        # The backslash form is parsed by the sender as a POST to evil.example,
        # even though another parser reports the host as fcm.googleapis.com.
        for endpoint in (
            "https://evil.example/abc",
            "https://fcm.googleapis.com.evil.example/abc",
            "https://notfcm.googleapis.com/abc",
            "https://notify.windows.com.evil.example/abc",
            "https://push.apple.com/abc",
            "https://evil.example\\@fcm.googleapis.com/abc",
        ):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(accepts_push_endpoint(endpoint))


if __name__ == "__main__":
    unittest.main()
