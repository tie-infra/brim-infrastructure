#!/usr/bin/env python3
"""Declarative OpenWrt deployer for broom with fw4 check and 60s auto-rollback."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


UCI_LINE_RE = re.compile(r"^([^.=]+)\.([^.=]+)(?:\.([^=]+))?=(.*)$")


@dataclass(frozen=True)
class SecretValue:
    path: tuple[str, ...]
    plaintext: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.plaintext.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class RemoteState:
    packages: set[str]
    file_hashes: dict[str, str | None]
    uci_sections: dict[str, dict[str, str]]
    uci_options: dict[str, dict[str, dict[str, str | list[str]]]]
    secret_hashes: dict[str, str | None]


def sh_quote(value: str) -> str:
    return shlex.quote(value)


def unquote_uci_value(raw: str) -> str:
    if len(raw) >= 2 and raw[0] == "'" and raw[-1] == "'":
        return raw[1:-1].replace("'\\''", "'")
    return raw


def parse_uci_list_value(raw: str) -> list[str]:
    """Parse OpenWrt `uci show` list output such as `'a' 'b'` or `'foo' 'bar baz'`."""
    items: list[str] = []
    i = 0
    n = len(raw)
    while i < n:
        while i < n and raw[i].isspace():
            i += 1
        if i >= n:
            break
        if raw[i] == "'":
            i += 1
            buf: list[str] = []
            while i < n:
                if raw[i] == "'":
                    if raw[i : i + 4] == "'\\''":
                        buf.append("'")
                        i += 4
                    else:
                        i += 1
                        break
                else:
                    buf.append(raw[i])
                    i += 1
            items.append("".join(buf))
        else:
            start = i
            while i < n and not raw[i].isspace():
                i += 1
            items.append(raw[start:i])
    return items


def parse_uci_show(text: str, list_keys: set[tuple[str, str, str]]) -> tuple[dict[str, str], dict[str, dict[str, str | list[str]]]]:
    """Parse `uci -q show <pkg>` into (sections_by_name, options_by_section)."""
    sections: dict[str, str] = {}
    options: dict[str, dict[str, str | list[str]]] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = UCI_LINE_RE.match(line)
        if not m:
            continue
        pkg, sec, opt, raw_val = m.groups()
        if opt is None:
            sections[sec] = unquote_uci_value(raw_val)
            options.setdefault(sec, {})
        else:
            sec_opts = options.setdefault(sec, {})
            if (pkg, sec, opt) in list_keys:
                sec_opts[opt] = parse_uci_list_value(raw_val)
            else:
                sec_opts[opt] = unquote_uci_value(raw_val)
    return sections, options


def resolve_secret(secrets_tree: dict[str, Any], path: list[str]) -> SecretValue:
    cur: Any = secrets_tree
    for segment in path:
        if not isinstance(cur, dict) or segment not in cur:
            joined = "/".join(path)
            raise KeyError(f"Secret path not found in SOPS file: {joined}")
        cur = cur[segment]
    if not isinstance(cur, str) or not cur.strip():
        joined = "/".join(path)
        raise ValueError(f"Secret value is empty or non-string: {joined}")
    return SecretValue(tuple(path), cur.strip())


def resolve_option_value(raw: Any, secrets_tree: dict[str, Any]) -> str | SecretValue:
    if isinstance(raw, dict) and "secretRef" in raw:
        ref = raw["secretRef"]
        if not isinstance(ref, list) or not all(isinstance(x, str) for x in ref):
            raise ValueError(f"Invalid secretRef: {raw!r}")
        return resolve_secret(secrets_tree, ref)
    if isinstance(raw, str):
        return raw
    raise ValueError(f"Unsupported UCI option value: {raw!r}")


def collect_secret_and_list_keys(spec: dict[str, Any]) -> tuple[list[tuple[str, str, str]], set[tuple[str, str, str]]]:
    secret_keys: list[tuple[str, str, str]] = []
    list_keys: set[tuple[str, str, str]] = set()
    for pkg, pkg_cfg in spec.get("uci", {}).items():
        for sec_cfg in pkg_cfg.get("sections", []):
            sec = sec_cfg["section"]
            for opt, val in sec_cfg.get("options", {}).items():
                if isinstance(val, dict) and "secretRef" in val:
                    secret_keys.append((pkg, sec, opt))
            for opt in sec_cfg.get("lists", {}):
                list_keys.add((pkg, sec, opt))
    return secret_keys, list_keys


def normalize_lf_bytes(path: Path) -> bytes:
    return path.read_bytes().replace(b"\r\n", b"\n")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_probe_script(spec: dict[str, Any], secret_keys: list[tuple[str, str, str]]) -> str:
    lines = [
        "set -eu",
        "echo '===PACKAGES==='",
        "apk info 2>/dev/null || true",
        "echo '===FILES==='",
    ]
    for fcfg in spec.get("files", []):
        dest = fcfg["dest"]
        qdest = sh_quote(dest)
        lines.append(
            f"if [ -f {qdest} ]; then printf '%s\\t%s\\n' {qdest} \"$(sha256sum {qdest} | awk '{{print $1}}')\"; "
            f"else printf '%s\\tMISSING\\n' {qdest}; fi"
        )

    lines.append("echo '===SECRET_HASHES==='")
    for pkg, sec, opt in secret_keys:
        key = f"{pkg}.{sec}.{opt}"
        qkey = sh_quote(key)
        lines.append(
            f"val=$(uci -q get {qkey} || true); "
            f"if [ -n \"$val\" ]; then printf '%s\\t%s\\n' {qkey} \"$(printf '%s' \"$val\" | sha256sum | awk '{{print $1}}')\"; "
            f"else printf '%s\\tMISSING\\n' {qkey}; fi"
        )

    secret_option_names = {f"{pkg}.{sec}.{opt}" for pkg, sec, opt in secret_keys}
    # Redact secret lines in `uci show` before they ever leave broom's stdout.
    sed_exprs = [f"-e {sh_quote(f'/^{re.escape(k)}=/d')}" for k in sorted(secret_option_names)]
    sed_filter = f" | sed {' '.join(sed_exprs)}" if sed_exprs else ""

    for pkg in spec.get("uci", {}):
        lines.append(f"echo {sh_quote(f'===UCI:{pkg}===')}")
        lines.append(f"(uci -q show {sh_quote(pkg)} || true){sed_filter}")

    lines.append("echo '===END==='")
    return "\n".join(lines) + "\n"


def parse_probe_output(output: str, list_keys: set[tuple[str, str, str]]) -> RemoteState:
    packages: set[str] = set()
    file_hashes: dict[str, str | None] = {}
    secret_hashes: dict[str, str | None] = {}
    uci_raw: dict[str, list[str]] = {}

    section: str | None = None
    for line in output.splitlines():
        if line.startswith("===") and line.endswith("==="):
            marker = line[3:-3]
            if marker == "END":
                section = None
            else:
                section = marker
                if marker.startswith("UCI:"):
                    uci_raw.setdefault(marker[4:], [])
            continue
        if section == "PACKAGES":
            pkg = line.strip()
            if pkg:
                packages.add(pkg)
        elif section == "FILES":
            if "\t" in line:
                dest, h = line.split("\t", 1)
                file_hashes[dest] = None if h == "MISSING" else h.strip()
        elif section == "SECRET_HASHES":
            if "\t" in line:
                key, h = line.split("\t", 1)
                secret_hashes[key] = None if h == "MISSING" else h.strip()
        elif section and section.startswith("UCI:"):
            uci_raw[section[4:]].append(line)

    uci_sections: dict[str, dict[str, str]] = {}
    uci_options: dict[str, dict[str, dict[str, str | list[str]]]] = {}
    for pkg, pkg_lines in uci_raw.items():
        secs, opts = parse_uci_show("\n".join(pkg_lines), list_keys)
        uci_sections[pkg] = secs
        uci_options[pkg] = opts

    return RemoteState(
        packages=packages,
        file_hashes=file_hashes,
        uci_sections=uci_sections,
        uci_options=uci_options,
        secret_hashes=secret_hashes,
    )


def find_anonymous_duplicates(
    pkg_sections: dict[str, str],
    pkg_options: dict[str, dict[str, str | list[str]]],
    sec_type: str,
    match_name: str,
) -> list[str]:
    """Return anonymous section refs like `@redirect[2]` matching type & name, sorted highest index first."""
    matches: list[tuple[int, str]] = []
    prefix = f"@{sec_type}["
    for sec_id, stype in pkg_sections.items():
        if stype != sec_type or not sec_id.startswith(prefix) or not sec_id.endswith("]"):
            continue
        idx_str = sec_id[len(prefix) : -1]
        if not idx_str.isdigit():
            continue
        if pkg_options.get(sec_id, {}).get("name") == match_name:
            matches.append((int(idx_str), sec_id))
    matches.sort(key=lambda item: item[0], reverse=True)
    return [sec_id for _, sec_id in matches]


@dataclass
class DeployPlan:
    missing_packages: list[str]
    changed_files: list[dict[str, Any]]
    uci_commands: dict[str, list[str]]
    diff_lines: list[str]
    triggers: set[str]

    @property
    def has_changes(self) -> bool:
        return bool(self.changed_files or self.uci_commands)


def compute_plan(
    spec: dict[str, Any],
    repo_root: Path,
    secrets_tree: dict[str, Any],
    remote: RemoteState,
) -> DeployPlan:
    missing_packages = sorted(
        pkg for pkg in spec.get("requiredPackages", []) if pkg not in remote.packages
    )
    changed_files: list[dict[str, Any]] = []
    uci_commands: dict[str, list[str]] = {}
    diff_lines: list[str] = []
    triggers: set[str] = set()

    for fcfg in spec.get("files", []):
        src_path = repo_root / fcfg["source"]
        expected_hash = sha256_bytes(normalize_lf_bytes(src_path))
        dest = fcfg["dest"]
        current_hash = remote.file_hashes.get(dest)
        if current_hash != expected_hash:
            changed_files.append(fcfg)
            status = "create" if current_hash is None else "update"
            diff_lines.append(f"file [{status}] {dest} <- {fcfg['source']}")
            triggers.update(fcfg.get("triggers", []))

    for pkg, pkg_cfg in spec.get("uci", {}).items():
        pkg_cmds: list[str] = []
        pkg_sections = remote.uci_sections.get(pkg, {})
        pkg_options = remote.uci_options.get(pkg, {})

        # First collect anonymous-to-named section migrations (delete highest index first).
        anon_deletes: list[tuple[str, int, str]] = []
        for sec_cfg in pkg_cfg.get("sections", []):
            match_name = sec_cfg.get("replaceAnonymousByName")
            sec_type = sec_cfg.get("type")
            if match_name and sec_type:
                for anon_id in find_anonymous_duplicates(pkg_sections, pkg_options, sec_type, match_name):
                    idx = int(anon_id.split("[", 1)[1].rstrip("]"))
                    anon_deletes.append((sec_type, idx, anon_id))

        # Group by section type and sort descending by index so indices don't shift on delete.
        anon_deletes.sort(key=lambda item: (item[0], item[1]), reverse=True)
        for _stype, _idx, anon_id in anon_deletes:
            pkg_cmds.append(f"uci -q delete {sh_quote(f'{pkg}.{anon_id}')} || true")
            diff_lines.append(f"uci [migrate] delete anonymous {pkg}.{anon_id}")

        for sec_cfg in pkg_cfg.get("sections", []):
            sec = sec_cfg["section"]
            sec_type = sec_cfg.get("type")
            cur_opts = pkg_options.get(sec, {})

            if sec_type is not None and pkg_sections.get(sec) != sec_type:
                pkg_cmds.append(f"uci set {sh_quote(f'{pkg}.{sec}={sec_type}')}")
                diff_lines.append(f"uci [section] {pkg}.{sec}={sec_type}")

            for del_opt in sec_cfg.get("deleteOptions", []):
                if del_opt in cur_opts:
                    pkg_cmds.append(f"uci -q delete {sh_quote(f'{pkg}.{sec}.{del_opt}')} || true")
                    diff_lines.append(f"uci [delete] {pkg}.{sec}.{del_opt}")

            for opt, raw_val in sec_cfg.get("options", {}).items():
                resolved = resolve_option_value(raw_val, secrets_tree)
                if isinstance(resolved, SecretValue):
                    key = f"{pkg}.{sec}.{opt}"
                    cur_hash = remote.secret_hashes.get(key)
                    if cur_hash != resolved.sha256:
                        pkg_cmds.append(f"uci set {sh_quote(f'{key}={resolved.plaintext}')}")
                        diff_lines.append(f"uci [secret] {key} = <redacted>")
                else:
                    if cur_opts.get(opt) != resolved:
                        pkg_cmds.append(f"uci set {sh_quote(f'{pkg}.{sec}.{opt}={resolved}')}")
                        diff_lines.append(
                            f"uci [option] {pkg}.{sec}.{opt}: {cur_opts.get(opt)!r} -> {resolved!r}"
                        )

            for opt, desired_list in sec_cfg.get("lists", {}).items():
                cur_val = cur_opts.get(opt)
                cur_list = cur_val if isinstance(cur_val, list) else ([] if cur_val is None else [cur_val])
                if cur_list != desired_list:
                    pkg_cmds.append(f"uci -q delete {sh_quote(f'{pkg}.{sec}.{opt}')} || true")
                    for item in desired_list:
                        pkg_cmds.append(f"uci add_list {sh_quote(f'{pkg}.{sec}.{opt}={item}')}")
                    diff_lines.append(f"uci [list] {pkg}.{sec}.{opt}: {cur_list!r} -> {desired_list!r}")

        if pkg_cmds:
            pkg_cmds.append(f"uci commit {sh_quote(pkg)}")
            uci_commands[pkg] = pkg_cmds
            triggers.update(pkg_cfg.get("triggers", []))

    return DeployPlan(
        missing_packages=missing_packages,
        changed_files=changed_files,
        uci_commands=uci_commands,
        diff_lines=diff_lines,
        triggers=triggers,
    )


def build_apply_script(
    plan: DeployPlan,
    stage_dir: str,
    nonce: str,
    rollback_timeout: int,
    backup_paths: list[str],
) -> str:
    backup_targets = " ".join(sh_quote(p.lstrip("/")) for p in backup_paths)
    lines = [
        "#!/bin/sh",
        "set -eu",
        "umask 077",
        f"STAGE={sh_quote(stage_dir)}",
        "BACKUP=/tmp/broom-rollback.tar.gz",
        "ARMED=/tmp/broom-rollback.armed",
        f"NONCE={sh_quote(nonce)}",
        "trap 'rm -rf \"$STAGE\" /tmp/broom-apply.sh' EXIT",
        "",
        "# 1. Snapshot current configuration before mutating anything.",
        "rm -f \"$BACKUP\"",
        "EXIST=''",
        f"for p in {backup_targets}; do",
        "  if [ -e \"/$p\" ]; then EXIST=\"$EXIST $p\"; fi",
        "done",
        "if [ -n \"$EXIST\" ]; then",
        "  # shellcheck disable=SC2086",
        "  tar -czf \"$BACKUP\" -C / $EXIST",
        "  chmod 600 \"$BACKUP\"",
        "fi",
        "",
        "restore_now() {",
        "  if [ -f \"$BACKUP\" ]; then",
        "    tar -xzf \"$BACKUP\" -C / || true",
        "  fi",
        "  rm -f \"$ARMED\" \"$BACKUP\"",
        "}",
        "",
        "# 2. Install staged files.",
    ]

    for idx, fcfg in enumerate(plan.changed_files):
        dest = fcfg["dest"]
        mode = fcfg.get("mode", "0644")
        parent = posixpath.dirname(dest)
        lines.append(f"mkdir -p {sh_quote(parent)}")
        lines.append(f"cp \"$STAGE/file_{idx}\" {sh_quote(dest)}")
        lines.append(f"chmod {sh_quote(mode)} {sh_quote(dest)}")

    lines.append("")
    lines.append("# 3. Apply and commit UCI changes.")
    for pkg, cmds in plan.uci_commands.items():
        lines.append(f"# package: {pkg}")
        lines.extend(cmds)

    lines.extend(
        [
            "",
            "# 4. Ensure ru_ips.nft exists before fw4 check.",
            "if [ ! -f /etc/vpn-pbr/ru_ips.nft ] && [ -x /etc/vpn-pbr/update-ru-ips.sh ]; then",
            "  /etc/vpn-pbr/update-ru-ips.sh",
            "fi",
            "",
            "# 5. Pre-flight fw4 ruleset validation; roll back immediately on failure.",
            "if ! fw4 check; then",
            "  echo 'ERROR: fw4 check failed; restoring backup immediately' >&2",
            "  restore_now",
            "  exit 1",
            "fi",
            "",
            f"# 6. Arm {rollback_timeout}s automatic rollback watchdog before reloading services.",
            "printf '%s\\n' \"$NONCE\" > \"$ARMED\"",
            "chmod 600 \"$ARMED\"",
            "(",
            f"  sleep {rollback_timeout}",
            "  if [ -f \"$ARMED\" ] && [ \"$(cat \"$ARMED\" 2>/dev/null || true)\" = \"$NONCE\" ]; then",
            "    logger -t broom-deploy 'Rollback timer expired; restoring previous configuration'",
            "    if [ -f \"$BACKUP\" ]; then",
            "      tar -xzf \"$BACKUP\" -C / || true",
            "    fi",
            "    rm -f \"$ARMED\" \"$BACKUP\"",
            "    /etc/init.d/network reload || /etc/init.d/network restart || true",
            "    ifup awg0 || true",
            "    /etc/init.d/firewall restart || true",
            "    /etc/init.d/https-dns-proxy restart || true",
            "    /etc/init.d/dnsmasq restart || true",
            "    /etc/init.d/cron restart || true",
            "  fi",
            ") </dev/null >/dev/null 2>&1 &",
            "",
            "# 7. Reload only affected services (avoiding br-lan teardown).",
        ]
    )

    if "system" in plan.triggers:
        lines.append("/etc/init.d/system reload")
    if "network" in plan.triggers:
        lines.append("ubus call network reload")
        lines.append("ifup awg0")
    if "firewall" in plan.triggers:
        lines.append("/etc/init.d/firewall restart")
    if "https-dns-proxy" in plan.triggers:
        lines.append("/etc/init.d/https-dns-proxy restart")
    if "dnsmasq" in plan.triggers:
        lines.append("/etc/init.d/dnsmasq restart")
    if "cron" in plan.triggers:
        lines.append("/etc/init.d/cron restart")

    lines.append("echo 'APPLIED_AND_WATCHDOG_ARMED'")
    return "\n".join(lines) + "\n"


def build_ssh_base(host: str, identity: str | None, known_hosts: str | None) -> tuple[list[str], list[str]]:
    common = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    if identity:
        common.extend(["-i", identity])
    if known_hosts:
        common.extend(["-o", f"UserKnownHostsFile={known_hosts}"])
    return (["ssh", *common, host], ["scp", "-O", *common])


def decrypt_sops(sops_path: Path) -> dict[str, Any]:
    out = subprocess.check_output(
        ["sops", "--decrypt", "--output-type", "json", str(sops_path)],
        text=True,
    )
    return json.loads(out)


def run_ssh_script(ssh_base: list[str], script: str) -> str:
    payload = script.replace("\r\n", "\n").encode("utf-8")
    res = subprocess.run(
        [*ssh_base, "sh -s"],
        input=payload,
        capture_output=True,
        check=False,
    )
    if res.returncode != 0:
        sys.stderr.write(res.stderr.decode("utf-8", errors="replace"))
        raise RuntimeError(f"Remote command failed with exit code {res.returncode}")
    return res.stdout.decode("utf-8", errors="replace")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Declarative OpenWrt deployer for broom")
    parser.add_argument("action", choices=["check", "diff", "deploy"], help="Operation to execute")
    parser.add_argument("--config", default="hosts/broom/config.json", help="Path to broom config.json")
    parser.add_argument("--host", default=None, help="Override SSH target (default from config.json)")
    parser.add_argument("--identity", default=None, help="Optional SSH private key path")
    parser.add_argument("--known-hosts", default=None, help="Optional SSH known_hosts path")
    parser.add_argument("--force", action="store_true", help="Force reload even when already in sync")
    args = parser.parse_args(argv[1:])

    config_path = Path(args.config).resolve()
    spec: dict[str, Any] = json.loads(config_path.read_text(encoding="utf-8"))
    # Assume repository root is two levels up from hosts/broom/config.json unless cwd matches.
    repo_root = Path.cwd()
    if not (repo_root / spec["sopsFile"]).exists() and (config_path.parents[2] / spec["sopsFile"]).exists():
        repo_root = config_path.parents[2]

    host = args.host or spec["host"]
    ssh_base, scp_base = build_ssh_base(host, args.identity, args.known_hosts)
    secrets_tree = decrypt_sops(repo_root / spec["sopsFile"])
    secret_keys, list_keys = collect_secret_and_list_keys(spec)

    probe_out = run_ssh_script(ssh_base, build_probe_script(spec, secret_keys))
    remote = parse_probe_output(probe_out, list_keys)
    plan = compute_plan(spec, repo_root, secrets_tree, remote)

    if plan.missing_packages:
        print("Missing required OpenWrt packages on broom:", ", ".join(plan.missing_packages))
    else:
        print(f"Packages OK ({len(spec.get('requiredPackages', []))} verified).")

    if plan.diff_lines:
        print(f"Planned changes ({len(plan.diff_lines)}):")
        for line in plan.diff_lines:
            print(f"  - {line}")
    else:
        print("Configuration is in sync (0 changes).")

    if args.action == "diff":
        return 0
    if args.action == "check":
        if plan.missing_packages or plan.has_changes:
            return 2
        return 0

    # deploy
    if plan.missing_packages:
        print("Refusing to deploy while required packages are missing.", file=sys.stderr)
        return 1
    if not plan.has_changes and not args.force:
        print("Nothing to deploy.")
        return 0

    if args.force and not plan.triggers:
        plan.triggers.update({"firewall", "dnsmasq", "https-dns-proxy", "cron"})

    nonce = secrets.token_hex(16)
    stage_dir = f"/tmp/broom-stage-{nonce[:8]}"
    rollback_timeout = int(spec.get("rollbackTimeoutSeconds", 60))
    backup_paths = [
        "/etc/config",
        "/usr/share/nftables.d/ruleset-post",
        "/etc/vpn-pbr/update-ru-ips.sh",
        "/etc/crontabs/root",
        "/etc/apk/repositories.d/customfeeds.list",
    ]
    apply_script = build_apply_script(plan, stage_dir, nonce, rollback_timeout, backup_paths)

    with tempfile.TemporaryDirectory(prefix="broom-deploy-") as tmpdir:
        tmp = Path(tmpdir)
        run_ssh_script(ssh_base, f"umask 077 && mkdir -p {sh_quote(stage_dir)}\n")
        for idx, fcfg in enumerate(plan.changed_files):
            local_stage = tmp / f"file_{idx}"
            local_stage.write_bytes(normalize_lf_bytes(repo_root / fcfg["source"]))
            subprocess.check_call([*scp_base, str(local_stage), f"{host}:{stage_dir}/file_{idx}"])

        local_apply = tmp / "broom-apply.sh"
        local_apply.write_text(apply_script, encoding="utf-8", newline="\n")
        subprocess.check_call([*scp_base, str(local_apply), f"{host}:/tmp/broom-apply.sh"])

    print(f"Applying changes on {host} with {rollback_timeout}s automatic rollback safety net...")
    apply_out = run_ssh_script(ssh_base, "chmod 600 /tmp/broom-apply.sh && sh /tmp/broom-apply.sh\n")
    if "APPLIED_AND_WATCHDOG_ARMED" not in apply_out:
        print("Unexpected apply output; leaving rollback watchdog armed.", file=sys.stderr)
        return 1

    print("Verifying router health on a fresh SSH connection and disarming rollback...")
    verify_script = "\n".join(
        [
            "set -eu",
            "fw4 check >/dev/null",
            "nft list table inet vpn_pbr >/dev/null",
            "ip link show awg0 >/dev/null",
            "pgrep dnsmasq >/dev/null",
            "pgrep https-dns-proxy >/dev/null",
            f"test \"$(cat /tmp/broom-rollback.armed)\" = {sh_quote(nonce)}",
            "rm -f /tmp/broom-rollback.armed /tmp/broom-rollback.tar.gz",
            "echo 'DEPLOY_COMMITTED'",
        ]
    ) + "\n"
    verify_out = run_ssh_script(ssh_base, verify_script)
    if "DEPLOY_COMMITTED" not in verify_out:
        print("Health check failed; rollback watchdog will restore previous config!", file=sys.stderr)
        return 1

    print("Deploy verified and committed (rollback disarmed).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
