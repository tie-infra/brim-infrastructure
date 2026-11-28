import unittest
from pathlib import Path

import awg_failover as af


def mk_cc(ip: str, blocked: bool, summary: str = "ok") -> af.CheburcheckResult:
    return af.CheburcheckResult(
        target=ip,
        available=True,
        blocked=blocked,
        list_blocked=blocked,
        probe_ok=0 if blocked else 2,
        probe_blocked=2 if blocked else 0,
        probe_uncertain=0,
        verdicts_summary=summary,
    )


class AwgFailoverTests(unittest.TestCase):
    def test_parse_cheburcheck_sse_lines(self) -> None:
        lines = [
            "event: started\n",
            'data: {"id":"abc","target":"217.144.189.29","online_probes":3}\n',
            "\n",
            "event: result\n",
            'data: {"probe_id":"1","provider":"MTS","verdicts":["tspu_block"]}\n',
            "\n",
            "event: result\n",
            'data: {"probe_id":"2","provider":"Rostelecom","verdicts":["tspu_block","sni_block"]}\n',
            "\n",
            "event: result\n",
            'data: {"probe_id":"3","provider":"Beeline","verdicts":["ok"]}\n',
            "\n",
            "event: done\n",
            'data: {"status":"done","response_count":3,"online_probes":3}\n',
            "\n",
        ]
        ok_c, blk_c, unc_c, summary = af.parse_cheburcheck_sse_lines(lines)
        self.assertEqual((ok_c, blk_c, unc_c), (1, 2, 0))
        self.assertIn("MTS:tspu_block", summary)
        self.assertIn("blocked=2", summary)

    def test_parse_latest_handshake(self) -> None:
        raw = "peerA\t0\n8dBtOq2tRr89IWmUkH9Tja7iZeCXZStnDIip4L4alVI=\t1795820000\n"
        self.assertIsNone(af.parse_latest_handshake(raw, "peerA"))
        self.assertEqual(
            af.parse_latest_handshake(raw, "8dBtOq2tRr89IWmUkH9Tja7iZeCXZStnDIip4L4alVI="),
            1795820000,
        )

    def test_decide_failover_tspu_ban_switches_to_healthy_candidate(self) -> None:
        active = af.ProbeReport("217.144.189.29", False, None, mk_cc("217.144.189.29", True))
        cand = af.ProbeReport("77.221.155.29", True, 43.2, mk_cc("77.221.155.29", False))
        decision, target, _ = af.decide_failover(active, [cand])
        self.assertEqual(decision, "switch")
        self.assertEqual(target, "77.221.155.29")

    def test_decide_failover_lovit_only_ban_switches_even_if_cheburcheck_clean(self) -> None:
        active = af.ProbeReport("217.144.189.29", False, None, mk_cc("217.144.189.29", False))
        cand = af.ProbeReport("77.221.155.29", True, 44.1, mk_cc("77.221.155.29", False))
        decision, target, _ = af.decide_failover(active, [cand])
        self.assertEqual(decision, "switch")
        self.assertEqual(target, "77.221.155.29")

    def test_decide_failover_home_isp_outage_does_not_switch(self) -> None:
        active = af.ProbeReport("217.144.189.29", False, None, mk_cc("217.144.189.29", False))
        cand = af.ProbeReport("77.221.155.29", False, None, mk_cc("77.221.155.29", False))
        decision, target, _ = af.decide_failover(active, [cand])
        self.assertEqual(decision, "isp_outage")
        self.assertIsNone(target)

    def test_decide_failover_all_blocked_alerts_without_switching(self) -> None:
        active = af.ProbeReport("217.144.189.29", False, None, mk_cc("217.144.189.29", True))
        cand = af.ProbeReport("77.221.155.29", False, None, mk_cc("77.221.155.29", True))
        decision, target, _ = af.decide_failover(active, [cand])
        self.assertEqual(decision, "all_blocked")
        self.assertIsNone(target)

    def test_decide_failover_tunnel_only_issue_does_not_switch(self) -> None:
        active = af.ProbeReport("217.144.189.29", True, 46.5, mk_cc("217.144.189.29", False))
        decision, target, _ = af.decide_failover(active, [])
        self.assertEqual(decision, "tunnel_only")
        self.assertIsNone(target)

    def test_build_nft_snat_script(self) -> None:
        cfg = af.Config(
            interface="awg0",
            wan_interface="eth0",
            gateway="10.0.0.1",
            fw_mark="0x6600",
            route_table=110,
            policy_rule_priority=100,
            candidates=("217.144.189.29", "77.221.155.29"),
            peer_public_key="pub",
            peer_endpoint="broom.brim.su:41763",
            peer_wan_ip="195.170.194.163",
            tunnel_local_ip="10.66.0.1",
            tunnel_peer_ip="10.66.0.2",
            snat_subnet="10.66.0.0/23",
            nft_table="inet vpn-nat",
            nft_chain="postrouting-v4",
            wan_probe_targets=("9.9.9.10",),
            check_interval_seconds=30,
            failure_threshold=3,
            handshake_max_age_seconds=180,
            cooldown_seconds=900,
            recovery_wait_seconds=20,
            cheburcheck_base_url="https://cheburcheck.ru/api/v1",
            cheburcheck_timeout_seconds=35,
            state_file=Path("/tmp/state.json"),
            telegram_bot_token_cred=None,
            telegram_chat_id_cred=None,
            cheburcheck_api_token_cred=None,
        )
        script = af.build_nft_snat_script(cfg, "77.221.155.29")
        self.assertIn("flush chain inet vpn-nat postrouting-v4", script)
        self.assertIn('oifname "eth0" ip saddr 10.66.0.0/23 snat ip to 77.221.155.29', script)


if __name__ == "__main__":
    unittest.main()
