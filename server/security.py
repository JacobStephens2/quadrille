"""Password hashing (Argon2id) and opaque-token helpers."""
import hashlib
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError

# Argon2id with the library defaults (modern, OWASP-aligned).
_ph = PasswordHasher()


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        _ph.verify(password_hash, password)
        return True
    except (VerifyMismatchError, InvalidHashError):
        return False


def needs_rehash(password_hash: str) -> bool:
    try:
        return _ph.check_needs_rehash(password_hash)
    except InvalidHashError:
        return True


def new_opaque_token() -> str:
    """A 256-bit URL-safe secret. Only its hash is stored server-side."""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
