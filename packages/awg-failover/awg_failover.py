#!/usr/bin/env python3
"""Event-driven IPv4 TSPU failover daemon for AmneziaWG on bram."""

from __future__ import annotations

import argparse
import dataclasses
import http.client
import json
import os
import re
import signal
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


BLOCKED_VERDICTS = frozenset({"tspu_block", "cdn_block", "sni_block", "dns_spoofing"})
OK_VERDICTS = frozenset({"ok", "whitelist"})


@dataclass(frozen=True)
class Config:
    interface: str
    wan_interface: str
    gateway: str
    fw_mark: str
    route_table: int
    policy_rule_priority: int
    candidates: tuple[str, ...]
    peer_public_key: str
    peer_endpoint: str
    peer_wan_ip: str
    tunnel_local_ip: str
    tunnel_peer_ip: str
    snat_subnet: str
    nft_table: str
    nft_chain: str
    wan_probe_targets: tuple[str, ...]
    check_interval_seconds: int
    failure_threshold: int
    handshake_max_age_seconds: int
    cooldown_seconds: int
    recovery_wait_seconds: int
    cheburcheck_base_url: str
    cheburcheck_timeout_seconds: int
    state_file: Path
    telegram_bot_token_cred: str | None
    telegram_chat_id_cred: str | None
    cheburcheck_api_token_cred: str | None


@dataclass(frozen=True)
class CheburcheckResult:
    target: str
    available: bool
    blocked: bool
    list_blocked: bool
    probe_ok: int
    probe_blocked: int
    probe_uncertain: int
    verdicts_summary: str
    error: str | None = None


@dataclass(frozen=True)
class ProbeReport:
    ip: str
    broom_ping_ok: bool
    broom_rtt_ms: float | None
    cheburcheck: CheburcheckResult


@dataclass
class FailoverState:
    active_ip: str
    last_switch_ts: float = 0.0
    last_alert_ts: float = 0.0
    last_alert_kind: str = ""


def load_config(path: Path) -> Config:
    raw = json.loads(path.read_text(encoding="utf-8"))
    candidates = tuple(raw["candidates"])
    if not candidates:
        raise ValueError("candidates must be non-empty")
    return Config(
        interface=raw["interface"],
        wan_interface=raw["wanInterface"],
        gateway=raw["gateway"],
        fw_mark=str(raw["fwMark"]),
        route_table=int(raw["routeTable"]),
        policy_rule_priority=int(raw.get("policyRulePriority", 100)),
        candidates=candidates,
        peer_public_key=raw["peerPublicKey"],
        peer_endpoint=raw["peerEndpoint"],
        peer_wan_ip=raw["peerWanIp"],
        tunnel_local_ip=raw["tunnelLocalIp"],
        tunnel_peer_ip=raw["tunnelPeerIp"],
        snat_subnet=raw["snatSubnet"],
        nft_table=raw["nftTable"],
        nft_chain=raw["nftChain"],
        wan_probe_targets=tuple(raw.get("wanProbeTargets", ["9.9.9.10", "1.1.1.1"])),
        check_interval_seconds=int(raw.get("checkIntervalSeconds", 30)),
        failure_threshold=int(raw.get("failureThreshold", 3)),
        handshake_max_age_seconds=int(raw.get("handshakeMaxAgeSeconds", 180)),
        cooldown_seconds=int(raw.get("cooldownSeconds", 900)),
        recovery_wait_seconds=int(raw.get("recoveryWaitSeconds", 20)),
        cheburcheck_base_url=raw.get("cheburcheckBaseUrl", "https://cheburcheck.ru/api/v1").rstrip("/"),
        cheburcheck_timeout_seconds=int(raw.get("cheburcheckTimeoutSeconds", 35)),
        state_file=Path(raw.get("stateFile", "/var/lib/awg-failover/state.json")),
        telegram_bot_token_cred=raw.get("telegramBotTokenCredential"),
        telegram_chat_id_cred=raw.get("telegramChatIdCredential"),
        cheburcheck_api_token_cred=raw.get("cheburcheckApiTokenCredential"),
    )


def read_optional_credential(cred_dir: Path | None, name: str | None) -> str | None:
    if not cred_dir or not name:
        return None
    p = cred_dir / name
    if not p.exists():
        return None
    val = p.read_text(encoding="utf-8").strip()
    return val or None


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    sys.stderr.write(f"[{ts}] {msg}\n")
    sys.stderr.flush()


def load_state(cfg: Config) -> FailoverState:
    if cfg.state_file.exists():
        try:
            data = json.loads(cfg.state_file.read_text(encoding="utf-8"))
            active = str(data.get("active_ip", ""))
            if active in cfg.candidates:
                return FailoverState(
                    active_ip=active,
                    last_switch_ts=float(data.get("last_switch_ts", 0.0)),
                    last_alert_ts=float(data.get("last_alert_ts", 0.0)),
                    last_alert_kind=str(data.get("last_alert_kind", "")),
                )
        except Exception as exc:
            log(f"WARN: could not parse state file {cfg.state_file}: {exc}")
    return FailoverState(active_ip=cfg.candidates[0])


def save_state(cfg: Config, state: FailoverState) -> None:
    cfg.state_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = cfg.state_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(dataclasses.asdict(state), indent=2) + "\n", encoding="utf-8")
    tmp.replace(cfg.state_file)


def run_cmd(args: list[str], stdin_text: str | None = None, timeout: int = 15) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        input=stdin_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


RTT_RE = re.compile(r"rtt min/avg/max/mdev = [0-9.]+/([0-9.]+)/")


def ping_ipv4(target: str, source_ip: str | None = None, count: int = 2, timeout: int = 2) -> tuple[bool, float | None]:
    cmd = ["ping", "-4", "-c", str(count), "-W", str(timeout), "-i", "0.3"]
    if source_ip:
        cmd.extend(["-I", source_ip])
    cmd.append(target)
    res = run_cmd(cmd, timeout=max(5, count * timeout + 3))
    if res.returncode != 0:
        return False, None
    m = RTT_RE.search(res.stdout)
    return True, (float(m.group(1)) if m else None)


def ping_ipv6(target: str, count: int = 2, timeout: int = 2) -> bool:
    cmd = ["ping", "-6", "-c", str(count), "-W", str(timeout), "-i", "0.3", target]
    res = run_cmd(cmd, timeout=max(5, count * timeout + 3))
    return res.returncode == 0


def parse_latest_handshake(awg_output: str, peer_public_key: str) -> int | None:
    for line in awg_output.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0] == peer_public_key:
            try:
                ts = int(parts[1])
                return ts if ts > 0 else None
            except ValueError:
                return None
    return None


def get_handshake_age(cfg: Config, now: float | None = None) -> float | None:
    res = run_cmd(["awg", "show", cfg.interface, "latest-handshakes"], timeout=5)
    if res.returncode != 0:
        return None
    ts = parse_latest_handshake(res.stdout, cfg.peer_public_key)
    if ts is None:
        return None
    cur = time.time() if now is None else now
    return max(0.0, cur - ts)


def check_tunnel_health(cfg: Config) -> tuple[bool, float | None, float | None]:
    ping_ok, rtt = ping_ipv4(cfg.tunnel_peer_ip, source_ip=cfg.tunnel_local_ip, count=2, timeout=2)
    hs_age = get_handshake_age(cfg)
    if ping_ok:
        return True, rtt, hs_age
    return False, None, hs_age


def check_wan_health(cfg: Config, active_ip: str) -> bool:
    for target in cfg.wan_probe_targets:
        ok, _ = ping_ipv4(target, source_ip=active_ip, count=2, timeout=2)
        if ok:
            return True
    # Also try IPv6 Quad9 in case active IPv4 itself is experiencing issues.
    return ping_ipv6("2620:fe::10", count=2, timeout=2)


def normalize_fwmark_int(fw_mark: str) -> int:
    return int(fw_mark, 0)


def build_nft_snat_script(cfg: Config, ip: str) -> str:
    return (
        f"flush chain {cfg.nft_table} {cfg.nft_chain}\n"
        f'add rule {cfg.nft_table} {cfg.nft_chain} oifname "{cfg.wan_interface}" '
        f"ip saddr {cfg.snat_subnet} snat ip to {ip}\n"
    )


def get_live_route_src(table: str | int) -> str | None:
    res = run_cmd(["ip", "-4", "route", "show", "default", "table", str(table)], timeout=5)
    if res.returncode != 0:
        return None
    m = re.search(r"\bsrc\s+([0-9.]+)\b", res.stdout)
    return m.group(1) if m else None


def get_live_nft_snat_ip(cfg: Config) -> str | None:
    table_parts = cfg.nft_table.split()
    res = run_cmd(["nft", "list", "chain", *table_parts, cfg.nft_chain], timeout=5)
    if res.returncode != 0:
        return None
    m = re.search(r"\bsnat ip to ([0-9.]+)\b", res.stdout)
    return m.group(1) if m else None


def has_fwmark_rule(cfg: Config) -> bool:
    res = run_cmd(["ip", "-4", "rule", "show"], timeout=5)
    if res.returncode != 0:
        return False
    mark_int = normalize_fwmark_int(cfg.fw_mark)
    mark_hex = hex(mark_int)
    pattern = re.compile(
        rf"^{cfg.policy_rule_priority}:\s+.*\bfwmark\s+(?:{re.escape(mark_hex)}|{mark_int})\b.*\blookup\s+{cfg.route_table}\b"
    )
    return any(pattern.search(line.strip()) for line in res.stdout.splitlines())


def apply_active_ip(cfg: Config, ip: str, reset_peer_endpoint: bool = True) -> None:
    if not has_fwmark_rule(cfg):
        res = run_cmd(
            [
                "ip",
                "-4",
                "rule",
                "add",
                "priority",
                str(cfg.policy_rule_priority),
                "fwmark",
                cfg.fw_mark,
                "lookup",
                str(cfg.route_table),
            ]
        )
        if res.returncode != 0:
            raise RuntimeError(f"ip rule add failed: {res.stderr.strip()}")

    for route_args in (
        [
            "ip",
            "-4",
            "route",
            "replace",
            "default",
            "via",
            cfg.gateway,
            "dev",
            cfg.wan_interface,
            "onlink",
            "src",
            ip,
            "table",
            str(cfg.route_table),
        ],
        [
            "ip",
            "-4",
            "route",
            "replace",
            "default",
            "via",
            cfg.gateway,
            "dev",
            cfg.wan_interface,
            "onlink",
            "src",
            ip,
        ],
    ):
        res = run_cmd(route_args)
        if res.returncode != 0:
            raise RuntimeError(f"{' '.join(route_args)} failed: {res.stderr.strip()}")

    nft_script = build_nft_snat_script(cfg, ip)
    res = run_cmd(["nft", "-f", "-"], stdin_text=nft_script)
    if res.returncode != 0:
        raise RuntimeError(f"nft SNAT update failed: {res.stderr.strip()}")

    if reset_peer_endpoint:
        # Re-setting the peer endpoint clears WireGuard/AmneziaWG's cached
        # peer->endpoint.src4 so the next datagram immediately uses the new
        # source IP from table 110 without restarting the interface.
        res = run_cmd(
            [
                "awg",
                "set",
                cfg.interface,
                "peer",
                cfg.peer_public_key,
                "endpoint",
                cfg.peer_endpoint,
            ]
        )
        if res.returncode != 0:
            raise RuntimeError(f"awg set endpoint failed: {res.stderr.strip()}")


def reconcile_active_ip(cfg: Config, active_ip: str) -> bool:
    table_src = get_live_route_src(cfg.route_table)
    main_src = get_live_route_src("main")
    nft_ip = get_live_nft_snat_ip(cfg)
    rule_ok = has_fwmark_rule(cfg)
    if table_src == active_ip and main_src == active_ip and nft_ip == active_ip and rule_ok:
        return False
    log(
        f"Reconciling routing/SNAT to {active_ip} "
        f"(table={table_src}, main={main_src}, nft={nft_ip}, rule={rule_ok})"
    )
    apply_active_ip(cfg, active_ip, reset_peer_endpoint=(table_src != active_ip))
    return True


def _https_connect_prefer_ipv6(host: str, port: int, timeout: int) -> http.client.HTTPSConnection:
    """Open an HTTPSConnection preferring IPv6 so a banned active IPv4 does not block API calls."""
    ctx = ssl.create_default_context()
    last_exc: Exception | None = None
    for family in (socket.AF_INET6, socket.AF_INET):
        try:
            infos = socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)
        except OSError as exc:
            last_exc = exc
            continue
        for af, socktype, proto, _canon, sockaddr in infos:
            sock: socket.socket | None = None
            try:
                sock = socket.socket(af, socktype, proto)
                sock.settimeout(timeout)
                sock.connect(sockaddr)
                tls_sock = ctx.wrap_socket(sock, server_hostname=host)
                conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
                conn.sock = tls_sock
                return conn
            except OSError as exc:
                last_exc = exc
                if sock is not None:
                    try:
                        sock.close()
                    except OSError:
                        pass
    raise OSError(f"Could not connect to {host}:{port}: {last_exc}")


def parse_cheburcheck_sse_lines(lines: list[str]) -> tuple[int, int, int, str]:
    """Parse Cheburcheck /api/v1/probe/<id> SSE stream lines into (ok, blocked, uncertain, summary)."""
    event_name: str | None = None
    data_lines: list[str] = []
    ok_count = 0
    blocked_count = 0
    uncertain_count = 0
    details: list[str] = []

    def flush() -> bool:
        nonlocal event_name, data_lines, ok_count, blocked_count, uncertain_count
        if not event_name and not data_lines:
            return False
        raw_data = "\n".join(data_lines).strip()
        ev = event_name or "message"
        event_name = None
        data_lines = []
        if ev == "done":
            return True
        if ev != "result" or not raw_data:
            return False
        try:
            payload = json.loads(raw_data)
        except json.JSONDecodeError:
            return False
        verdicts = set(payload.get("verdicts") or [])
        provider = payload.get("provider") or payload.get("region") or f"probe#{payload.get('probe_id', '?')}"
        if verdicts & BLOCKED_VERDICTS:
            blocked_count += 1
            details.append(f"{provider}:{','.join(sorted(verdicts))}")
        elif verdicts & OK_VERDICTS:
            ok_count += 1
        else:
            uncertain_count += 1
            if verdicts:
                details.append(f"{provider}:{','.join(sorted(verdicts))}")
        return False

    for raw_line in lines:
        line = raw_line.rstrip("\r\n")
        if line == "":
            if flush():
                break
            continue
        if line.startswith(":"):
            continue
        if line.startswith("event:"):
            event_name = line[6:].strip()
        elif line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
    else:
        flush()

    summary = f"probes ok={ok_count}, blocked={blocked_count}, uncertain={uncertain_count}"
    if details:
        summary += f" ({'; '.join(details[:4])})"
    return ok_count, blocked_count, uncertain_count, summary


def query_cheburcheck(cfg: Config, target_ip: str, api_token: str | None) -> CheburcheckResult:
    parsed = urllib.parse.urlsplit(cfg.cheburcheck_base_url)
    host = parsed.hostname or "cheburcheck.ru"
    port = parsed.port or 443
    base_path = parsed.path.rstrip("/")
    headers = {"User-Agent": "awg-failover/0.1", "Accept": "application/json"}

    try:
        conn = _https_connect_prefer_ipv6(host, port, timeout=10)
        try:
            check_path = f"{base_path}/check?target={urllib.parse.quote(target_ip, safe='')}"
            conn.request("GET", check_path, headers=headers)
            resp = conn.getresponse()
            body = resp.read().decode("utf-8", errors="replace")
            if resp.status != 200:
                return CheburcheckResult(
                    target=target_ip,
                    available=False,
                    blocked=False,
                    list_blocked=False,
                    probe_ok=0,
                    probe_blocked=0,
                    probe_uncertain=0,
                    verdicts_summary=f"HTTP {resp.status}",
                    error=f"check HTTP {resp.status}",
                )
            check_data = json.loads(body)
        finally:
            conn.close()
    except Exception as exc:
        return CheburcheckResult(
            target=target_ip,
            available=False,
            blocked=False,
            list_blocked=False,
            probe_ok=0,
            probe_blocked=0,
            probe_uncertain=0,
            verdicts_summary="unavailable",
            error=str(exc),
        )

    list_blocked = bool(check_data.get("blocked", False))
    check_id = check_data.get("id")
    ok_c = 0
    blocked_c = 0
    uncertain_c = 0
    summary = f"list_blocked={list_blocked}"

    if api_token and isinstance(check_id, str) and check_id:
        try:
            conn = _https_connect_prefer_ipv6(host, port, timeout=cfg.cheburcheck_timeout_seconds)
            try:
                probe_path = f"{base_path}/probe/{urllib.parse.quote(check_id, safe='')}"
                probe_headers = {
                    "User-Agent": "awg-failover/0.1",
                    "Accept": "text/event-stream",
                    "Authorization": f"Bearer {api_token}",
                }
                conn.request("GET", probe_path, headers=probe_headers)
                resp = conn.getresponse()
                if resp.status == 200:
                    sse_lines: list[str] = []
                    deadline = time.monotonic() + cfg.cheburcheck_timeout_seconds
                    while time.monotonic() < deadline:
                        raw_line = resp.readline()
                        if not raw_line:
                            break
                        decoded = raw_line.decode("utf-8", errors="replace")
                        sse_lines.append(decoded)
                        if decoded.strip() == "event: done":
                            # Read remaining data line(s) for done event.
                            for _ in range(3):
                                extra = resp.readline()
                                if not extra:
                                    break
                                d_extra = extra.decode("utf-8", errors="replace")
                                sse_lines.append(d_extra)
                                if d_extra.strip() == "":
                                    break
                            break
                    ok_c, blocked_c, uncertain_c, probe_sum = parse_cheburcheck_sse_lines(sse_lines)
                    summary = f"list_blocked={list_blocked}; {probe_sum}"
                else:
                    summary = f"list_blocked={list_blocked}; probe HTTP {resp.status}"
            finally:
                conn.close()
        except Exception as exc:
            summary = f"list_blocked={list_blocked}; probe error: {exc}"

    probes_say_blocked = (blocked_c > 0) and (blocked_c >= ok_c)
    return CheburcheckResult(
        target=target_ip,
        available=True,
        blocked=(list_blocked or probes_say_blocked),
        list_blocked=list_blocked,
        probe_ok=ok_c,
        probe_blocked=blocked_c,
        probe_uncertain=uncertain_c,
        verdicts_summary=summary,
    )


def decide_failover(
    active_report: ProbeReport,
    candidate_reports: list[ProbeReport],
) -> tuple[str, str | None, str]:
    """Decide failover action from active and candidate probe reports.

    Returns (decision, target_ip, reason) where decision is one of:
    - "switch": switch active IP to target_ip
    - "isp_outage": broom appears offline across all IPs; keep current IP
    - "all_blocked": active IP is blocked/unreachable and no healthy candidate exists
    - "tunnel_only": active IP still pings broom and is not blocked (e.g. remote awg issue)
    """
    active_bad = active_report.cheburcheck.blocked or (not active_report.broom_ping_ok)
    if not active_bad:
        return (
            "tunnel_only",
            None,
            f"Active IP {active_report.ip} still pings broom and is not flagged blocked",
        )

    healthy_candidates = [
        r for r in candidate_reports if r.broom_ping_ok and (not r.cheburcheck.blocked)
    ]
    if healthy_candidates:
        chosen = healthy_candidates[0]
        cause = "Cheburcheck confirmed block" if active_report.cheburcheck.blocked else "active IP cannot reach broom while candidate can"
        return ("switch", chosen.ip, f"{cause}; switching {active_report.ip} -> {chosen.ip}")

    if active_report.cheburcheck.blocked:
        return (
            "all_blocked",
            None,
            f"Active IP {active_report.ip} is blocked and no healthy candidate is reachable",
        )

    return (
        "isp_outage",
        None,
        "broom is unreachable from all bram IPv4 addresses (likely home ISP outage)",
    )


def send_telegram(bot_token: str | None, chat_id: str | None, text: str) -> bool:
    if not bot_token or not chat_id:
        log("Telegram notification skipped (credentials not configured)")
        return False
    payload = json.dumps(
        {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": True,
        }
    ).encode("utf-8")
    try:
        conn = _https_connect_prefer_ipv6("api.telegram.org", 443, timeout=15)
        try:
            conn.request(
                "POST",
                f"/bot{bot_token}/sendMessage",
                body=payload,
                headers={"Content-Type": "application/json", "User-Agent": "awg-failover/0.1"},
            )
            resp = conn.getresponse()
            _ = resp.read()
            if resp.status == 200:
                log("Telegram notification delivered")
                return True
            log(f"ERROR: Telegram API returned HTTP {resp.status}")
            return False
        finally:
            conn.close()
    except Exception as exc:
        # Never expose bot_token in error logs.
        safe_err = str(exc).replace(bot_token, "<redacted>")
        log(f"ERROR: Telegram delivery failed: {safe_err}")
        return False


def wait_for_recovery(cfg: Config) -> tuple[bool, float | None]:
    deadline = time.monotonic() + cfg.recovery_wait_seconds
    while time.monotonic() < deadline:
        ok, rtt = ping_ipv4(cfg.tunnel_peer_ip, source_ip=cfg.tunnel_local_ip, count=1, timeout=2)
        if ok:
            return True, rtt
        time.sleep(2)
    return False, None


def format_report_line(r: ProbeReport) -> str:
    ping_str = f"OK ({r.broom_rtt_ms:.1f} ms)" if (r.broom_ping_ok and r.broom_rtt_ms is not None) else ("OK" if r.broom_ping_ok else "FAIL")
    return f"• {r.ip}: ping broom={ping_str} | cheburcheck: {r.cheburcheck.verdicts_summary}"


def handle_incident(
    cfg: Config,
    state: FailoverState,
    bot_token: str | None,
    chat_id: str | None,
    chebur_token: str | None,
) -> None:
    now = time.time()
    if now - state.last_switch_ts < cfg.cooldown_seconds:
        remaining = int(cfg.cooldown_seconds - (now - state.last_switch_ts))
        log(f"Tunnel unhealthy, but switch cooldown active ({remaining}s remaining)")
        return

    if not check_wan_health(cfg, state.active_ip):
        log("WARN: bram WAN connectivity check failed; skipping failover")
        return

    log(f"Tunnel {cfg.interface} failed {cfg.failure_threshold} checks; probing active IP {state.active_ip}")
    active_ping_ok, active_rtt = ping_ipv4(cfg.peer_wan_ip, source_ip=state.active_ip, count=2, timeout=2)
    active_cc = query_cheburcheck(cfg, state.active_ip, chebur_token)
    active_report = ProbeReport(
        ip=state.active_ip,
        broom_ping_ok=active_ping_ok,
        broom_rtt_ms=active_rtt,
        cheburcheck=active_cc,
    )
    log(format_report_line(active_report))

    candidate_reports: list[ProbeReport] = []
    if active_cc.blocked or not active_ping_ok:
        for cand_ip in cfg.candidates:
            if cand_ip == state.active_ip:
                continue
            c_ping_ok, c_rtt = ping_ipv4(cfg.peer_wan_ip, source_ip=cand_ip, count=2, timeout=2)
            # Only spend a Cheburcheck API call on a candidate if it can actually reach broom
            # (or if Cheburcheck already confirmed active IP was blocked).
            if c_ping_ok or active_cc.blocked:
                c_cc = query_cheburcheck(cfg, cand_ip, chebur_token)
            else:
                c_cc = CheburcheckResult(
                    target=cand_ip,
                    available=True,
                    blocked=False,
                    list_blocked=False,
                    probe_ok=0,
                    probe_blocked=0,
                    probe_uncertain=0,
                    verdicts_summary="skipped (broom unreachable)",
                )
            rep = ProbeReport(ip=cand_ip, broom_ping_ok=c_ping_ok, broom_rtt_ms=c_rtt, cheburcheck=c_cc)
            candidate_reports.append(rep)
            log(format_report_line(rep))

    decision, target_ip, reason = decide_failover(active_report, candidate_reports)
    log(f"Decision: {decision} ({reason})")

    if decision == "switch" and target_ip:
        old_ip = state.active_ip
        apply_active_ip(cfg, target_ip, reset_peer_endpoint=True)
        state.active_ip = target_ip
        state.last_switch_ts = time.time()
        state.last_alert_ts = state.last_switch_ts
        state.last_alert_kind = "switch"
        save_state(cfg, state)

        recovered, rec_rtt = wait_for_recovery(cfg)
        rec_text = (
            f"восстановлен ({rec_rtt:.1f} ms)" if (recovered and rec_rtt is not None) else (
                "восстановлен" if recovered else "пока не отвечает (ждёт handshake)"
            )
        )
        lines = [
            f"🔄 bram awg-failover: смена IPv4",
            f"Старый IP: {old_ip}",
            f"Новый IP: {target_ip}",
            f"Причина: {reason}",
            f"Туннель {cfg.interface}: {rec_text}",
            "",
            "Диагностика:",
            format_report_line(active_report),
            *(format_report_line(r) for r in candidate_reports),
        ]
        send_telegram(bot_token, chat_id, "\n".join(lines))
        return

    # Rate-limit non-switch alerts (at most once per cooldown window for the same kind).
    if state.last_alert_kind == decision and (now - state.last_alert_ts) < cfg.cooldown_seconds:
        return

    state.last_alert_ts = now
    state.last_alert_kind = decision
    save_state(cfg, state)

    icon = "🚨" if decision == "all_blocked" else "⚠️"
    title = {
        "isp_outage": "bram awg-failover: похоже на обрыв домашнего интернета (IP не переключён)",
        "all_blocked": "bram awg-failover: активный IP заблокирован, здоровых кандидатов нет",
        "tunnel_only": "bram awg-failover: awg0 недоступен, но IP пингует broom (IP не переключён)",
    }.get(decision, f"bram awg-failover: {decision}")
    lines = [
        f"{icon} {title}",
        f"Активный IP: {state.active_ip}",
        f"Причина: {reason}",
        "",
        "Диагностика:",
        format_report_line(active_report),
        *(format_report_line(r) for r in candidate_reports),
    ]
    send_telegram(bot_token, chat_id, "\n".join(lines))


def run_daemon(cfg: Config, cred_dir: Path | None) -> int:
    bot_token = read_optional_credential(cred_dir, cfg.telegram_bot_token_cred)
    chat_id = read_optional_credential(cred_dir, cfg.telegram_chat_id_cred)
    chebur_token = read_optional_credential(cred_dir, cfg.cheburcheck_api_token_cred)

    state = load_state(cfg)
    reconcile_active_ip(cfg, state.active_ip)
    save_state(cfg, state)
    log(
        f"Started awg-failover on {cfg.interface}: active_ip={state.active_ip}, "
        f"candidates={list(cfg.candidates)}, telegram={'on' if (bot_token and chat_id) else 'off'}, "
        f"cheburcheck_probe_token={'on' if chebur_token else 'off'}"
    )

    running = True

    def _stop(_signum: int, _frame: Any) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    consecutive_failures = 0
    while running:
        try:
            reconcile_active_ip(cfg, state.active_ip)
            healthy, rtt, hs_age = check_tunnel_health(cfg)
            if healthy:
                if consecutive_failures > 0:
                    rtt_str = f"{rtt:.1f}ms" if rtt is not None else "ok"
                    log(f"Tunnel {cfg.interface} healthy again (rtt={rtt_str}, active_ip={state.active_ip})")
                consecutive_failures = 0
            else:
                consecutive_failures += 1
                hs_str = f"{int(hs_age)}s" if hs_age is not None else "none"
                log(
                    f"Tunnel {cfg.interface} check failed ({consecutive_failures}/{cfg.failure_threshold}, "
                    f"active_ip={state.active_ip}, hs_age={hs_str})"
                )
                if consecutive_failures >= cfg.failure_threshold:
                    handle_incident(cfg, state, bot_token, chat_id, chebur_token)
                    consecutive_failures = 0
        except Exception as exc:
            safe_err = str(exc)
            if bot_token:
                safe_err = safe_err.replace(bot_token, "<redacted>")
            if chebur_token:
                safe_err = safe_err.replace(chebur_token, "<redacted>")
            log(f"ERROR in failover loop: {safe_err}")

        # Sleep in 1s slices for responsive SIGTERM shutdown.
        for _ in range(cfg.check_interval_seconds):
            if not running:
                break
            time.sleep(1)

    log("Shutting down awg-failover")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="AmneziaWG IPv4 TSPU failover daemon")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_daemon = sub.add_parser("daemon")
    p_daemon.add_argument("config", type=Path)

    p_status = sub.add_parser("status")
    p_status.add_argument("config", type=Path)

    p_switch = sub.add_parser("switch")
    p_switch.add_argument("config", type=Path)
    p_switch.add_argument("ip")
    p_switch.add_argument("--notify", action="store_true")

    p_test = sub.add_parser("test-notify")
    p_test.add_argument("config", type=Path)

    args = parser.parse_args(argv[1:])
    cfg = load_config(args.config)
    cred_dir_env = os.environ.get("CREDENTIALS_DIRECTORY")
    cred_dir = Path(cred_dir_env) if cred_dir_env else None

    if args.cmd == "daemon":
        return run_daemon(cfg, cred_dir)

    if args.cmd == "status":
        state = load_state(cfg)
        healthy, rtt, hs_age = check_tunnel_health(cfg)
        out = {
            "state_active_ip": state.active_ip,
            "candidates": list(cfg.candidates),
            "route_table_src": get_live_route_src(cfg.route_table),
            "main_route_src": get_live_route_src("main"),
            "nft_snat_ip": get_live_nft_snat_ip(cfg),
            "fwmark_rule_present": has_fwmark_rule(cfg),
            "tunnel_healthy": healthy,
            "tunnel_rtt_ms": rtt,
            "handshake_age_seconds": round(hs_age, 1) if hs_age is not None else None,
        }
        print(json.dumps(out, indent=2))
        return 0

    if args.cmd == "switch":
        if args.ip not in cfg.candidates:
            sys.stderr.write(f"ERROR: {args.ip} is not in candidates {list(cfg.candidates)}\n")
            return 2
        state = load_state(cfg)
        old_ip = state.active_ip
        apply_active_ip(cfg, args.ip, reset_peer_endpoint=True)
        state.active_ip = args.ip
        state.last_switch_ts = time.time()
        save_state(cfg, state)
        recovered, rtt = wait_for_recovery(cfg)
        print(
            json.dumps(
                {
                    "old_ip": old_ip,
                    "new_ip": args.ip,
                    "recovered": recovered,
                    "rtt_ms": rtt,
                },
                indent=2,
            )
        )
        if args.notify:
            bot_token = read_optional_credential(cred_dir, cfg.telegram_bot_token_cred)
            chat_id = read_optional_credential(cred_dir, cfg.telegram_chat_id_cred)
            rec = f"OK ({rtt:.1f} ms)" if (recovered and rtt is not None) else ("OK" if recovered else "FAIL")
            send_telegram(
                bot_token,
                chat_id,
                f"🔧 bram awg-failover: ручное переключение IPv4\n{old_ip} → {args.ip}\nТуннель {cfg.interface}: {rec}",
            )
        return 0 if recovered else 1

    if args.cmd == "test-notify":
        bot_token = read_optional_credential(cred_dir, cfg.telegram_bot_token_cred)
        chat_id = read_optional_credential(cred_dir, cfg.telegram_chat_id_cred)
        state = load_state(cfg)
        ok = send_telegram(
            bot_token,
            chat_id,
            f"✅ bram awg-failover подключён.\nАктивный IPv4: {state.active_ip}\nКандидаты: {', '.join(cfg.candidates)}",
        )
        return 0 if ok else 1

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
