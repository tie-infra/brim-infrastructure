#!/usr/bin/env python3
"""Minimal Happ/Marzban-compatible VPN subscription server (stdlib only)."""

from __future__ import annotations

import base64
import hashlib
import hmac
import http.server
import json
import os
import signal
import socket
import socketserver
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit


@dataclass(frozen=True)
class UserCreds:
    hy2_password: str
    vless_uuid: str


@dataclass(frozen=True)
class AppState:
    host: str
    port: int
    server_host: str
    hy2_port: int
    hy2_sni: str
    vless_port: int
    reality_sni: str
    reality_public_key: str
    reality_short_id: str
    profile_title_b64: str
    update_interval: int
    marzban_secret: str
    hy2_obfs: str
    users: dict[str, UserCreds]


def read_credential(cred_dir: Path, name: str) -> str:
    path = cred_dir / name
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise ValueError(f"empty credential file: {path}")
    return value


def b64url_decode(segment: str) -> bytes:
    padded = segment + ("=" * (-len(segment) % 4))
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def validate_token(token: str, secret: str, now: float | None = None) -> str | None:
    """Validate a Marzban hash token or legacy HS256 subscription JWT.

    Returns the authenticated username or None if invalid.
    """
    if len(token) < 15 or any(ch.isspace() for ch in token):
        return None

    secret_bytes = secret.encode("utf-8")

    # Legacy HS256 JWT (header.payload.signature)
    if token.count(".") == 2:
        header_b64, payload_b64, sig_b64 = token.split(".")
        if not (header_b64 and payload_b64 and sig_b64):
            return None
        try:
            header = json.loads(b64url_decode(header_b64).decode("utf-8"))
        except Exception:
            return None
        if not isinstance(header, dict) or header.get("alg") != "HS256":
            return None

        signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
        expected_sig = b64url_encode(hmac.new(secret_bytes, signing_input, hashlib.sha256).digest())
        if not hmac.compare_digest(sig_b64, expected_sig):
            return None

        try:
            payload = json.loads(b64url_decode(payload_b64).decode("utf-8"))
        except Exception:
            return None
        if not isinstance(payload, dict):
            return None
        if payload.get("access") != "subscription":
            return None
        exp = payload.get("exp")
        if exp is not None:
            current_time = time.time() if now is None else now
            try:
                if current_time >= float(exp):
                    return None
            except (TypeError, ValueError):
                return None
        sub = payload.get("sub")
        return sub if isinstance(sub, str) and sub else None

    # Marzban hash token: base64url(f"{username},{ts}").rstrip("=") + base64url(sha256(payload_b64 + secret))[:10]
    payload_b64 = token[:-10]
    sig = token[-10:]
    digest = hashlib.sha256(payload_b64.encode("utf-8") + secret_bytes).digest()
    expected_sig = b64url_encode(digest)[:10]
    if not hmac.compare_digest(sig, expected_sig):
        return None

    try:
        decoded = b64url_decode(payload_b64).decode("utf-8")
    except Exception:
        return None

    parts = decoded.split(",")
    if len(parts) != 2 or not parts[0]:
        return None
    try:
        int(parts[1])
    except ValueError:
        return None
    return parts[0]


def build_subscription_body(state: AppState, username: str) -> bytes:
    creds = state.users[username]
    hy2_uri = (
        f"hysteria2://{quote(creds.hy2_password, safe='')}@{state.server_host}:{state.hy2_port}/"
        f"?obfs=salamander&obfs-password={quote(state.hy2_obfs, safe='')}"
        f"&sni={quote(state.hy2_sni, safe='')}"
        f"#{quote('🇳🇱 Amsterdam (Hy2)')}"
    )
    vless_uri = (
        f"vless://{quote(creds.vless_uuid, safe='')}@{state.server_host}:{state.vless_port}"
        f"?encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni={quote(state.reality_sni, safe='')}&fp=chrome"
        f"&pbk={quote(state.reality_public_key, safe='')}"
        f"&sid={quote(state.reality_short_id, safe='')}&type=tcp"
        f"#{quote('🇳🇱 Amsterdam (VLESS)')}"
    )
    raw = f"{hy2_uri}\n{vless_uri}\n".encode("utf-8")
    return base64.b64encode(raw)


def load_state(config_path: Path, cred_dir: Path) -> AppState:
    cfg: dict[str, Any] = json.loads(config_path.read_text(encoding="utf-8"))
    users: dict[str, UserCreds] = {}
    for username, ucfg in cfg["users"].items():
        users[username] = UserCreds(
            hy2_password=read_credential(cred_dir, ucfg["hy2PasswordCredential"]),
            vless_uuid=read_credential(cred_dir, ucfg["vlessUuidCredential"]),
        )
    title_b64 = base64.b64encode(cfg["profileTitle"].encode("utf-8")).decode("ascii")
    return AppState(
        host=cfg["host"],
        port=int(cfg["port"]),
        server_host=cfg["serverHost"],
        hy2_port=int(cfg["hy2Port"]),
        hy2_sni=cfg["hy2Sni"],
        vless_port=int(cfg["vlessPort"]),
        reality_sni=cfg["realitySni"],
        reality_public_key=cfg["realityPublicKey"],
        reality_short_id=cfg["realityShortId"],
        profile_title_b64=title_b64,
        update_interval=int(cfg["updateInterval"]),
        marzban_secret=read_credential(cred_dir, cfg["marzbanSecretCredential"]),
        hy2_obfs=read_credential(cred_dir, cfg["hy2ObfsCredential"]),
        users=users,
    )


def make_handler(state: AppState) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "happ-sub"
        sys_version = ""

        def _handle(self, send_body: bool) -> None:
            path = urlsplit(self.path).path.rstrip("/")
            if path == "/healthz":
                body = b"ok\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if send_body:
                    self.wfile.write(body)
                return

            if not path.startswith("/sub/"):
                self._send_404(send_body)
                return

            token = path[len("/sub/"):]
            if "/" in token:
                self._send_404(send_body)
                return

            username = validate_token(token, state.marzban_secret)
            if username is None or username not in state.users:
                self._send_404(send_body)
                return

            body = build_subscription_body(state, username)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Profile-Update-Interval", str(state.update_interval))
            self.send_header("Profile-Title", f"base64:{state.profile_title_b64}")
            self.send_header("Content-Disposition", 'attachment; filename="subscription"')
            self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0; expire=0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if send_body:
                self.wfile.write(body)

        def _send_404(self, send_body: bool) -> None:
            body = b"Not Found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if send_body:
                self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            self._handle(send_body=True)

        def do_HEAD(self) -> None:  # noqa: N802
            self._handle(send_body=False)

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            # Never log raw /sub/<token> paths to avoid leaking subscription tokens.
            redacted_path = "/sub/<redacted>" if self.path.startswith("/sub/") else self.path
            status = args[1] if len(args) >= 2 else "-"
            sys.stderr.write(f"{self.command} {redacted_path} -> {status}\n")

    return Handler


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], handler_cls: type[http.server.BaseHTTPRequestHandler]) -> None:
        self.address_family = socket.AF_INET6 if ":" in server_address[0] else socket.AF_INET
        super().__init__(server_address, handler_cls)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <config.json>", file=sys.stderr)
        return 2

    cred_dir_env = os.environ.get("CREDENTIALS_DIRECTORY")
    if not cred_dir_env:
        print("CREDENTIALS_DIRECTORY is not set", file=sys.stderr)
        return 1

    state = load_state(Path(argv[1]), Path(cred_dir_env))
    server = ThreadingHTTPServer((state.host, state.port), make_handler(state))

    def _shutdown(_signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
