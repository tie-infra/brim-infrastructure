#!/usr/bin/env python3
"""Configure and tear down AmneziaWG 3.1 interfaces from structured JSON config."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


def is_ipv6(value: str) -> bool:
    return ":" in value


def cred_path(cred_dir: Path, name: str) -> str:
    path = cred_dir / name
    if not path.is_file():
        raise FileNotFoundError(f"missing systemd credential file: {path}")
    return str(path)


def build_awg_set_args(
    cfg: dict[str, Any],
    cred_dir: Path,
    stale_peers: list[str],
) -> list[str]:
    args = [
        "awg",
        "set",
        cfg["name"],
        "private-key",
        cred_path(cred_dir, cfg["privateKeyCredential"]),
    ]

    if cfg.get("listenPort") is not None:
        args.extend(["listen-port", str(cfg["listenPort"])])

    if cfg.get("fwMark") is not None:
        args.extend(["fwmark", str(cfg["fwMark"])])

    awg_opts: dict[str, Any] = cfg.get("awg", {})
    for key, value in awg_opts.items():
        if value is not None:
            args.extend([key, str(value)])

    hpk_cred = cfg.get("headerProtectionKeyCredential")
    if hpk_cred:
        args.extend(["header-protection-key", cred_path(cred_dir, hpk_cred)])

    for stale_pub in stale_peers:
        args.extend(["peer", stale_pub, "remove"])

    for peer in cfg.get("peers", []):
        args.extend(["peer", peer["publicKey"]])
        psk_cred = peer.get("presharedKeyCredential")
        if psk_cred:
            args.extend(["preshared-key", cred_path(cred_dir, psk_cred)])
        if peer.get("endpoint"):
            args.extend(["endpoint", peer["endpoint"]])
        if peer.get("persistentKeepalive") is not None:
            args.extend(["persistent-keepalive", str(peer["persistentKeepalive"])])
        allowed = peer.get("allowedIPs", [])
        if allowed:
            args.extend(["allowed-ips", ",".join(allowed)])

    return args


def build_rule_args(rule: dict[str, Any], action: str) -> list[str]:
    family = "-6" if is_ipv6(rule["from"]) else "-4"
    args = ["ip", family, "rule", action, "from", rule["from"], "lookup", str(rule["table"])]
    if rule.get("priority") is not None:
        args.extend(["priority", str(rule["priority"])])
    return args


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def interface_exists(name: str) -> bool:
    return run(["ip", "link", "show", "dev", name], check=False).returncode == 0


def current_peers(name: str) -> list[str]:
    res = run(["awg", "show", name, "peers"], check=False)
    if res.returncode != 0:
        return []
    return [line.strip() for line in res.stdout.splitlines() if line.strip()]


def bring_up(cfg: dict[str, Any], cred_dir: Path) -> None:
    name = cfg["name"]
    if not interface_exists(name):
        run(["ip", "link", "add", "dev", name, "type", "amneziawg"])

    if cfg.get("mtu") is not None:
        run(["ip", "link", "set", "dev", name, "mtu", str(cfg["mtu"])])

    desired_peers = {peer["publicKey"] for peer in cfg.get("peers", [])}
    stale = [p for p in current_peers(name) if p not in desired_peers]

    run(build_awg_set_args(cfg, cred_dir, stale))

    # Reconcile assigned addresses cleanly.
    run(["ip", "-4", "addr", "flush", "dev", name], check=False)
    run(["ip", "-6", "addr", "flush", "dev", name, "scope", "global"], check=False)
    for cidr in cfg.get("ips", []):
        family = "-6" if is_ipv6(cidr) else "-4"
        run(["ip", family, "addr", "replace", cidr, "dev", name])

    run(["ip", "link", "set", "dev", name, "up"])

    table = cfg.get("table")
    for route in cfg.get("routes", []):
        family = "-6" if is_ipv6(route) else "-4"
        cmd = ["ip", family, "route", "replace", route, "dev", name]
        if table is not None:
            cmd.extend(["table", str(table)])
        run(cmd)

    for rule in cfg.get("routingPolicyRules", []):
        run(build_rule_args(rule, "del"), check=False)
        run(build_rule_args(rule, "add"))


def bring_down(cfg: dict[str, Any]) -> None:
    for rule in cfg.get("routingPolicyRules", []):
        run(build_rule_args(rule, "del"), check=False)
    if interface_exists(cfg["name"]):
        run(["ip", "link", "del", "dev", cfg["name"]], check=False)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("up", "down"):
        print(f"usage: {argv[0]} <up|down> <config.json>", file=sys.stderr)
        return 2

    action, config_path = argv[1], argv[2]
    cfg = json.loads(Path(config_path).read_text(encoding="utf-8"))

    if action == "up":
        cred_dir_env = os.environ.get("CREDENTIALS_DIRECTORY")
        if not cred_dir_env:
            print("CREDENTIALS_DIRECTORY is not set", file=sys.stderr)
            return 1
        bring_up(cfg, Path(cred_dir_env))
    else:
        bring_down(cfg)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except subprocess.CalledProcessError as exc:
        if exc.stderr:
            sys.stderr.write(exc.stderr)
        raise SystemExit(exc.returncode) from exc
