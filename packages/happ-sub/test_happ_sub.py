import base64
import hashlib
import hmac
import http.client
import json
import threading
import time
import unittest

import happ_sub as mod


def make_marzban_token(username: str, secret: str, ts: int = 1700000000) -> str:
    payload = f"{username},{ts}".encode("utf-8")
    payload_b64 = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    sig = base64.urlsafe_b64encode(
        hashlib.sha256((payload_b64 + secret).encode("utf-8")).digest()
    ).decode("ascii").rstrip("=")[:10]
    return payload_b64 + sig


def make_hs256_jwt(payload: dict, secret: str) -> str:
    header_b64 = mod.b64url_encode(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    payload_b64 = mod.b64url_encode(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    sig = mod.b64url_encode(
        hmac.new(secret.encode("utf-8"), f"{header_b64}.{payload_b64}".encode("ascii"), hashlib.sha256).digest()
    )
    return f"{header_b64}.{payload_b64}.{sig}"


class TestHappSub(unittest.TestCase):
    SECRET = "test-marzban-jwt-secret-1234567890"

    def setUp(self) -> None:
        self.state = mod.AppState(
            host="127.0.0.1",
            port=0,
            server_host="relay.brim.su",
            hy2_port=8443,
            hy2_sni="relay.brim.su",
            vless_port=8443,
            reality_sni="brim.su",
            reality_public_key="REALITY_PUB_KEY",
            reality_short_id="0123456789abcdef",
            profile_title_b64=base64.b64encode("🦊 VPN".encode("utf-8")).decode("ascii"),
            update_interval=12,
            marzban_secret=self.SECRET,
            hy2_obfs="obfs-pass-123",
            users={
                "brim": mod.UserCreds(hy2_password="hy2-brim-pass", vless_uuid="11111111-1111-4111-8111-111111111111"),
                "ojegova": mod.UserCreds(hy2_password="hy2-babushka-pass", vless_uuid="22222222-2222-4222-8222-222222222222"),
            },
        )
        self.server = mod.ThreadingHTTPServer(("127.0.0.1", 0), mod.make_handler(self.state))
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def _get(self, path: str, method: str = "GET") -> tuple[int, dict[str, str], bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path)
        resp = conn.getresponse()
        body = resp.read()
        headers = {k.lower(): v for k, v in resp.getheaders()}
        conn.close()
        return resp.status, headers, body

    def test_marzban_hash_token_valid(self) -> None:
        token = make_marzban_token("ojegova", self.SECRET)
        status, headers, body = self._get(f"/sub/{token}")
        self.assertEqual(status, 200)
        self.assertEqual(headers["profile-update-interval"], "12")
        self.assertEqual(
            headers["profile-title"],
            "base64:" + base64.b64encode("🦊 VPN".encode("utf-8")).decode("ascii"),
        )
        self.assertEqual(headers["content-disposition"], 'attachment; filename="subscription"')
        self.assertEqual(headers["subscription-userinfo"], "upload=0; download=0; total=0; expire=0")

        decoded = base64.b64decode(body).decode("utf-8").splitlines()
        self.assertEqual(len(decoded), 2)
        self.assertTrue(decoded[0].startswith("hysteria2://hy2-babushka-pass@relay.brim.su:8443/"))
        self.assertIn("obfs=salamander", decoded[0])
        self.assertIn("obfs-password=obfs-pass-123", decoded[0])
        self.assertTrue(decoded[1].startswith("vless://22222222-2222-4222-8222-222222222222@relay.brim.su:8443?"))
        self.assertIn("security=reality", decoded[1])
        self.assertIn("sni=brim.su", decoded[1])
        self.assertIn("pbk=REALITY_PUB_KEY", decoded[1])
        self.assertIn("sid=0123456789abcdef", decoded[1])

    def test_legacy_hs256_jwt_valid(self) -> None:
        token = make_hs256_jwt({"sub": "brim", "access": "subscription", "iat": int(time.time())}, self.SECRET)
        status, _, body = self._get(f"/sub/{token}")
        self.assertEqual(status, 200)
        decoded = base64.b64decode(body).decode("utf-8")
        self.assertIn("hy2-brim-pass", decoded)
        self.assertIn("11111111-1111-4111-8111-111111111111", decoded)

    def test_disallowed_user_berlord_returns_404(self) -> None:
        token = make_marzban_token("berlord", self.SECRET)
        status, _, _ = self._get(f"/sub/{token}")
        self.assertEqual(status, 404)

    def test_tampered_and_wrong_access_tokens_return_404(self) -> None:
        good = make_marzban_token("brim", self.SECRET)
        bad_sig = good[:-1] + ("A" if good[-1] != "A" else "B")
        self.assertEqual(self._get(f"/sub/{bad_sig}")[0], 404)

        admin_jwt = make_hs256_jwt({"sub": "brim", "access": "sudo", "iat": int(time.time())}, self.SECRET)
        self.assertEqual(self._get(f"/sub/{admin_jwt}")[0], 404)

        expired_jwt = make_hs256_jwt({"sub": "brim", "access": "subscription", "exp": 1000}, self.SECRET)
        self.assertEqual(self._get(f"/sub/{expired_jwt}")[0], 404)

    def test_head_and_healthz(self) -> None:
        token = make_marzban_token("brim", self.SECRET)
        status, headers, body = self._get(f"/sub/{token}", method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(headers["profile-update-interval"], "12")

        h_status, _, h_body = self._get("/healthz")
        self.assertEqual(h_status, 200)
        self.assertEqual(h_body, b"ok\n")


if __name__ == "__main__":
    unittest.main()
