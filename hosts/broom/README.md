# `broom` (OpenWrt 25.12.6, SNR-CPE-AX2)

Declarative OpenWrt configuration for the home router `broom` (`broom.brim.su`, LAN `192.168.1.1/24`, WAN Lovit IPv4).

## What is managed

- **Files (`hosts/broom/files/`):**
  - `/etc/vpn-pbr/update-ru-ips.sh` — fetches aggregated RU IPv4 CIDRs from IPdeny, validates `>= 4000` entries, and atomically reloads `inet vpn_pbr ru_ips`.
  - `/usr/share/nftables.d/ruleset-post/90-vpn-pbr.nft` — kernel-space split routing (`table inet vpn_pbr`):
    - marks new inbound WAN connections with `ct mark |= 0x2` so return traffic for all 4 WAN→LAN port forwards (`7290`, `47989`, `47984`, `42022`) and reverse-proxied ports always leaves via WAN;
    - keeps local subnets, DNS (`53`/`853`), VPS/DNS bypass IPs, `@ru_ips`, and `@ru_dns_ips` on WAN;
    - marks remaining foreign LAN IPv4 traffic with `0x1` for policy table `100` (`awg0`).
  - `/etc/crontabs/root` — daily `04:15` refresh of `/etc/vpn-pbr/ru_ips.nft`.
  - `/etc/apk/repositories.d/customfeeds.list` — signed `2Grey/awg-openwrt` feed for AmneziaWG 3.1.
- **UCI (`hosts/broom/config.json`):**
  - `system`: hostname `broom`, UTC timezone, NTP, WAN LED.
  - `network`: `wan` (Quad9 DNS10, `peerdns=0`), `wan6` disabled, passive `awg0` (AWG 3.1 on `41763/udp`, `10.66.0.2/30`, MTU `1300`), `awg0_bram` peer, table `100` default route + source/mark rules.
  - `dhcp`: `dnsmasq-full` (`filter_aaaa=1`, `noresolv=1`), static DHCP leases, `ipset 'ru_dns'` populating `inet vpn_pbr ru_dns_ips`.
  - `firewall`: `vpn` zone (`awg0`, `masq=1`, `mtu_fix=1`), `lan -> vpn` forwarding, `Allow-AWG-Bram` (`41763/udp` restricted to `bram` IPs), and the 4 WAN→LAN port forwards (`PubgWebRadar`, `Moonlight`, `MoonlightHTTPS`, `DMA`).
  - `https-dns-proxy`: Quad9 DNS10 DoH (`https://dns10.quad9.net/dns-query`, `force_dns=1`).
- **Secrets (`secrets/broom.sops.yaml`):**
  - Encrypted with `admin_tie` and `admin_brim` only (`amneziawg.bram.{private-key,header-protection-key,preshared-key}`). Never stored in plaintext in Git or printed in diffs.
- **Unmanaged on purpose:** `wireless` (Wi-Fi SSID/WPA), `dropbear` SSH keys, `br-lan` bridge ports, and hardware MAC/DUID values remain untouched.

## Usage

```sh
# Read-only drift summary (secrets are compared by SHA-256 hash on broom)
task diff:broom

# Strict read-only check (exits non-zero on drift or missing packages)
task check:broom

# Apply changes with backup, fw4 check, and 60-second automatic rollback
task deploy:broom
```

Outside `nix develop` (for example on Windows), run the script directly with Python 3:

```sh
python packages/broom-deploy/broom_deploy.py diff --config hosts/broom/config.json
python packages/broom-deploy/broom_deploy.py deploy --config hosts/broom/config.json
```

### Safety & rollback

`broom-deploy deploy` snapshots `/etc/config` and all managed files to `/tmp/broom-rollback.tar.gz`, runs `fw4 check` before restarting any service (rolling back immediately if validation fails), arms a 60-second automatic rollback watchdog on `broom`, reloads only changed services without tearing down `br-lan`, verifies health over a **fresh** SSH connection (`fw4 check`, `vpn_pbr` table, `awg0`, `dnsmasq`, `https-dns-proxy`), and only then disarms the watchdog.
