import hashlib
import tempfile
import unittest
from pathlib import Path

import broom_deploy as bd


class BroomDeployTests(unittest.TestCase):
    def test_parse_uci_list_value_with_quotes_and_spaces(self) -> None:
        self.assertEqual(bd.parse_uci_list_value("'tcp' 'udp'"), ["tcp", "udp"])
        self.assertEqual(
            bd.parse_uci_list_value("'link tx rx' 'a'\\''b'"),
            ["link tx rx", "a'b"],
        )

    def test_parse_uci_show_and_find_anonymous_duplicates(self) -> None:
        sample = "\n".join(
            [
                "firewall.@redirect[0]=redirect",
                "firewall.@redirect[0].name='PubgWebRadar'",
                "firewall.@redirect[0].proto='tcp' 'udp'",
                "firewall.@redirect[1]=redirect",
                "firewall.@redirect[1].name='DMA'",
                "firewall.redirect_dma=redirect",
                "firewall.redirect_dma.name='DMA'",
            ]
        )
        secs, opts = bd.parse_uci_show(sample, {("firewall", "@redirect[0]", "proto")})
        self.assertEqual(secs["@redirect[0]"], "redirect")
        self.assertEqual(opts["@redirect[0]"]["proto"], ["tcp", "udp"])
        self.assertEqual(
            bd.find_anonymous_duplicates(secs, opts, "redirect", "DMA"),
            ["@redirect[1]"],
        )

    def test_compute_plan_redacts_secrets_and_detects_in_sync(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "test.nft"
            src.write_bytes(b"table inet vpn_pbr {}\r\n")
            secret_plain = "SUPER_SECRET_KEY_VALUE"
            secret_hash = hashlib.sha256(secret_plain.encode("utf-8")).hexdigest()

            spec = {
                "requiredPackages": ["amneziawg-tools"],
                "files": [
                    {
                        "source": "test.nft",
                        "dest": "/usr/share/nftables.d/ruleset-post/90-vpn-pbr.nft",
                        "mode": "0644",
                        "triggers": ["firewall"],
                    }
                ],
                "uci": {
                    "network": {
                        "triggers": ["network"],
                        "sections": [
                            {
                                "section": "awg0",
                                "type": "interface",
                                "options": {
                                    "listen_port": "41763",
                                    "private_key": {"secretRef": ["amneziawg", "bram", "private-key"]},
                                },
                                "lists": {"addresses": ["10.66.0.2/30"]},
                            }
                        ],
                    }
                },
            }
            secrets_tree = {"amneziawg": {"bram": {"private-key": secret_plain}}}

            # Case 1: drifted secret + missing file -> never leaks plaintext in diff_lines
            drifted_remote = bd.RemoteState(
                packages={"amneziawg-tools"},
                file_hashes={"/usr/share/nftables.d/ruleset-post/90-vpn-pbr.nft": None},
                uci_sections={"network": {"awg0": "interface"}},
                uci_options={
                    "network": {
                        "awg0": {
                            "listen_port": "41763",
                            "addresses": ["10.66.0.2/30"],
                        }
                    }
                },
                secret_hashes={"network.awg0.private_key": "0" * 64},
            )
            plan = bd.compute_plan(spec, root, secrets_tree, drifted_remote)
            self.assertTrue(plan.has_changes)
            self.assertEqual(plan.triggers, {"firewall", "network"})
            for line in plan.diff_lines:
                self.assertNotIn(secret_plain, line)
            self.assertTrue(any("<redacted>" in line for line in plan.diff_lines))

            # Case 2: completely in sync
            synced_remote = bd.RemoteState(
                packages={"amneziawg-tools"},
                file_hashes={
                    "/usr/share/nftables.d/ruleset-post/90-vpn-pbr.nft": bd.sha256_bytes(
                        b"table inet vpn_pbr {}\n"
                    )
                },
                uci_sections={"network": {"awg0": "interface"}},
                uci_options={
                    "network": {
                        "awg0": {
                            "listen_port": "41763",
                            "addresses": ["10.66.0.2/30"],
                        }
                    }
                },
                secret_hashes={"network.awg0.private_key": secret_hash},
            )
            plan_sync = bd.compute_plan(spec, root, secrets_tree, synced_remote)
            self.assertFalse(plan_sync.has_changes)
            self.assertEqual(plan_sync.diff_lines, [])

    def test_build_apply_script_includes_fw4_check_and_rollback(self) -> None:
        plan = bd.DeployPlan(
            missing_packages=[],
            changed_files=[{"dest": "/etc/crontabs/root", "mode": "0600"}],
            uci_commands={"firewall": ["uci set firewall.vpn=zone", "uci commit firewall"]},
            diff_lines=["uci [section] firewall.vpn=zone"],
            triggers={"firewall", "cron"},
        )
        script = bd.build_apply_script(plan, "/tmp/broom-stage-1234", "deadbeef", 60, ["/etc/config"])
        self.assertIn("fw4 check", script)
        self.assertIn("sleep 60", script)
        self.assertIn("/etc/init.d/firewall restart", script)
        self.assertIn("/etc/init.d/cron restart", script)
        self.assertNotIn("/etc/init.d/network reload", script.split("# 7. Reload")[1])


if __name__ == "__main__":
    unittest.main()
