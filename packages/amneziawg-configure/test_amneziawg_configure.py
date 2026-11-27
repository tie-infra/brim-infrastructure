import tempfile
import unittest
from pathlib import Path

import amneziawg_configure as mod


class TestAmneziawgConfigure(unittest.TestCase):
    def test_build_awg_set_args_uses_credential_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cred_dir = Path(tmp)
            (cred_dir / "private-key").write_text("SECRET_PRIV\n", encoding="utf-8")
            (cred_dir / "header-protection-key").write_text("SECRET_HPK\n", encoding="utf-8")
            (cred_dir / "preshared-key-0").write_text("SECRET_PSK\n", encoding="utf-8")

            cfg = {
                "name": "awg0",
                "listenPort": None,
                "fwMark": None,
                "privateKeyCredential": "private-key",
                "headerProtectionKeyCredential": "header-protection-key",
                "awg": {
                    "jc": 4,
                    "s1": 38,
                    "s2": 64,
                    "s3": 28,
                    "s4": 24,
                    "h1": "100-200",
                    "random-trailers": "on",
                    "disable-cookies": "on",
                },
                "peers": [
                    {
                        "publicKey": "PEER_PUB",
                        "presharedKeyCredential": "preshared-key-0",
                        "endpoint": "broom.brim.su:41763",
                        "persistentKeepalive": "15-20",
                        "allowedIPs": ["10.66.0.2/32"],
                    }
                ],
            }

            args = mod.build_awg_set_args(cfg, cred_dir, ["OLD_PEER"])

            self.assertNotIn("SECRET_PRIV", " ".join(args))
            self.assertNotIn("SECRET_HPK", " ".join(args))
            self.assertNotIn("SECRET_PSK", " ".join(args))
            self.assertIn(str(cred_dir / "private-key"), args)
            self.assertIn(str(cred_dir / "header-protection-key"), args)
            self.assertIn(str(cred_dir / "preshared-key-0"), args)
            self.assertLess(args.index("s4"), args.index("header-protection-key"))
            self.assertIn("OLD_PEER", args)
            self.assertEqual(args[args.index("OLD_PEER") + 1], "remove")
            self.assertEqual(args[args.index("persistent-keepalive") + 1], "15-20")

    def test_build_rule_args_ipv4_and_ipv6(self) -> None:
        self.assertEqual(
            mod.build_rule_args({"from": "10.66.1.2/32", "table": "100", "priority": 1000}, "add"),
            ["ip", "-4", "rule", "add", "from", "10.66.1.2/32", "lookup", "100", "priority", "1000"],
        )
        self.assertEqual(
            mod.build_rule_args({"from": "fd66:66:1::2/128", "table": "100"}, "del"),
            ["ip", "-6", "rule", "del", "from", "fd66:66:1::2/128", "lookup", "100"],
        )


if __name__ == "__main__":
    unittest.main()
