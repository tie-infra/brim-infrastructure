#!/bin/sh
set -eu

URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
DEST="/etc/vpn-pbr/ru_ips.nft"
TMP_ZONE="/tmp/ru-aggregated.zone.tmp"
TMP_ELEMS="/tmp/ru_ips.nft.tmp"
TMP_RELOAD="/tmp/ru_ips_reload.nft.tmp"

trap 'rm -f "$TMP_ZONE" "$TMP_ELEMS" "$TMP_RELOAD"' EXIT

mkdir -p /etc/vpn-pbr

curl -fsSL --max-time 30 "$URL" -o "$TMP_ZONE"

COUNT=$(grep -Ec '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$TMP_ZONE" || true)
if [ "${COUNT:-0}" -lt 4000 ]; then
	logger -t vpn-pbr "Refusing to update ru_ips: only ${COUNT:-0} valid CIDRs fetched"
	exit 1
fi

{
	printf 'elements = {\n'
	grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$TMP_ZONE" | sed 's/^/  /; s/$/,/'
	printf '}\n'
} > "$TMP_ELEMS"

if nft list set inet vpn_pbr ru_ips >/dev/null 2>&1; then
	{
		printf 'flush set inet vpn_pbr ru_ips\n'
		printf 'add element inet vpn_pbr ru_ips {\n'
		grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$TMP_ZONE" | sed 's/^/  /; s/$/,/'
		printf '}\n'
	} > "$TMP_RELOAD"
	nft -c -f "$TMP_RELOAD"
	nft -f "$TMP_RELOAD"
fi

if [ ! -f "$DEST" ] || ! cmp -s "$TMP_ELEMS" "$DEST"; then
	cp "$TMP_ELEMS" "$DEST"
	logger -t vpn-pbr "Updated $DEST with $COUNT Russian IPv4 CIDRs"
fi

echo "Loaded $COUNT Russian IPv4 CIDRs"
