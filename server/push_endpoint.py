"""Shared acceptance check for a Web Push subscription endpoint.

A subscription is stored or sent only when this check accepts it: https, a
push-service host, and no address literal. The host is the one requests will
contact (urllib3), so a URL that only looks allowlisted to another parser is
rejected.
"""
import ipaddress

import requests
from pywebpush import webpush
from urllib3.exceptions import LocationParseError
from urllib3.util import parse_url

# Browser Push API hosts. Exact names match the whole host. A suffix matches
# only on a dot boundary, so fcm.googleapis.com.evil.example is not a
# push-service host. List from the browser push services in use (Pushpad
# known-push-services): Chrome/FCM, legacy GCM, Firefox autopush, Safari,
# and Windows Notification Service.
_EXACT_HOSTS = frozenset(
    {
        "android.googleapis.com",
        "fcm.googleapis.com",
        "jmt17.google.com",
        "updates.push.services.mozilla.com",
        "updates-autopush.stage.mozaws.net",
        "updates-autopush.dev.mozaws.net",
    }
)
_HOST_SUFFIXES = (
    ".notify.windows.com",
    ".push.apple.com",
)

# Bound the push POST so a stalled endpoint cannot hold the worker.
PUSH_REQUEST_TIMEOUT_SECONDS = 10


def accepts_push_endpoint(endpoint: object) -> bool:
    """True when endpoint is https, a push-service host, and not an address literal."""
    if not isinstance(endpoint, str) or endpoint == "" or endpoint != endpoint.strip():
        return False
    try:
        parsed = parse_url(endpoint)
    except LocationParseError:
        return False
    if parsed.scheme != "https" or not parsed.host:
        return False
    if _is_address_literal(parsed.host):
        return False
    return _is_push_service_host(parsed.host)


def deliver_web_push(
    subscription_info: dict,
    data: str,
    *,
    vapid_private_key: str,
    vapid_claims: dict,
):
    """Send one subscription, or return None when the shared check rejects it.

    Sets a timeout and does not follow redirects.
    """
    endpoint = subscription_info.get("endpoint")
    if not accepts_push_endpoint(endpoint):
        return None
    with push_request_session() as session:
        return webpush(
            subscription_info=subscription_info,
            data=data,
            vapid_private_key=vapid_private_key,
            vapid_claims=vapid_claims,
            timeout=PUSH_REQUEST_TIMEOUT_SECONDS,
            requests_session=session,
        )


def push_request_session() -> requests.Session:
    """A session that does not follow redirects.

    A validated endpoint that answers 3xx must not bounce the POST to an
    unvalidated URL.
    """
    return _NoRedirectSession()


class _NoRedirectSession(requests.Session):
    def request(self, method, url, *args, **kwargs):
        kwargs["allow_redirects"] = False
        return super().request(method, url, *args, **kwargs)


def _is_address_literal(host: str) -> bool:
    # urllib3 keeps the brackets on an IPv6 literal. RFC 3986 only uses that
    # form for an address literal, including IPvFuture.
    if host.startswith("["):
        return True
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True


def _is_push_service_host(host: str) -> bool:
    name = host.lower().rstrip(".")
    if not name or ".." in name:
        return False
    if name in _EXACT_HOSTS:
        return True
    for suffix in _HOST_SUFFIXES:
        if not name.endswith(suffix):
            continue
        prefix = name[: -len(suffix)]
        if prefix and not prefix.startswith("."):
            return True
    return False
