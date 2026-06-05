"""Transactional email over SMTP. Provider-agnostic: reads SMTP_* env, so it
works with any SMTP provider; currently Resend (smtp.resend.com), swappable via env."""
import os
import smtplib
import ssl
from email.message import EmailMessage

BASE_URL = os.environ.get("QUADRILLE_BASE_URL", "https://quadrille.app")


def _send(to: str, subject: str, text: str, html: str | None = None) -> None:
    host = os.environ["SMTP_HOST"]
    port = int(os.environ.get("SMTP_PORT", "587"))
    user = os.environ["SMTP_USER"]
    password = os.environ["SMTP_PASS"]
    from_email = os.environ["SMTP_FROM_EMAIL"]
    from_name = os.environ.get("QUADRILLE_MAIL_FROM_NAME", "Quadrille")

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = f"{from_name} <{from_email}>"
    msg["To"] = to
    msg.set_content(text)
    if html:
        msg.add_alternative(html, subtype="html")

    with smtplib.SMTP(host, port, timeout=15) as smtp:
        smtp.starttls(context=ssl.create_default_context())
        smtp.login(user, password)
        smtp.send_message(msg)


def send_verification_email(to: str, token: str) -> None:
    link = f"{BASE_URL}/#/verify-email?token={token}"
    _send(
        to,
        "Verify your Quadrille email",
        f"Confirm your email to enable cloud sync:\n\n{link}\n\n"
        "This link expires in 24 hours. If you didn't create a Quadrille "
        "account, ignore this email.",
        f'<p>Confirm your email to enable cloud sync:</p>'
        f'<p><a href="{link}">Verify my email</a></p>'
        f"<p>This link expires in 24 hours.</p>",
    )


def send_password_reset_email(to: str, token: str) -> None:
    link = f"{BASE_URL}/#/reset-password?token={token}"
    _send(
        to,
        "Reset your Quadrille password",
        f"Reset your password:\n\n{link}\n\n"
        "This link expires in 1 hour. If you didn't request this, ignore "
        "this email — your password is unchanged.",
        f'<p>Reset your password:</p>'
        f'<p><a href="{link}">Reset password</a></p>'
        f"<p>This link expires in 1 hour. If you didn't request this, your "
        f"password is unchanged.</p>",
    )
