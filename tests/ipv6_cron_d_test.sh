#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v flock >/dev/null 2>&1; then
    echo "ipv6 cron.d test skipped: flock is unavailable"
    exit 0
fi

export INCUS_STATE_DIR="$TMP_DIR/state"
export ONECLICKVIRT_TESTING=1
export OCV_IPV6_CRON_DIR="$TMP_DIR/cron.d"
export OCV_IPV6_CRON_FILE="$TMP_DIR/cron.d/oneclickvirt-ipv6"
export OCV_IPV6_CRON_LOCK="$TMP_DIR/lock/ipv6-cron.lock"
mkdir -p "$INCUS_STATE_DIR" "$OCV_IPV6_CRON_DIR"
printf '%s\n' '# administrator entry' '15 2 * * * root /usr/local/bin/keep-me' >"$OCV_IPV6_CRON_FILE"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/build_ipv6_network.sh"

setup_ipv6_cron
grep -Fqx '# administrator entry' "$OCV_IPV6_CRON_FILE"
grep -Fqx '15 2 * * * root /usr/local/bin/keep-me' "$OCV_IPV6_CRON_FILE"
cron_line='*/1 * * * * root curl --noproxy '\''*'\'' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb && curl --noproxy '\''*'\'' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb'
[ "$(grep -Fxc "$cron_line" "$OCV_IPV6_CRON_FILE")" -eq 1 ]

before=$(sha256sum "$OCV_IPV6_CRON_FILE")
setup_ipv6_cron
[ "$before" = "$(sha256sum "$OCV_IPV6_CRON_FILE")" ]

for _ in $(seq 1 8); do setup_ipv6_cron & done
wait
[ "$(grep -Fxc "$cron_line" "$OCV_IPV6_CRON_FILE")" -eq 1 ]

mkdir -p "$TMP_DIR/cron-symlink-target"
ln -s "$TMP_DIR/cron-symlink-target" "$TMP_DIR/cron-symlink"
export OCV_IPV6_CRON_DIR="$TMP_DIR/cron-symlink"
export OCV_IPV6_CRON_FILE="$TMP_DIR/cron-symlink/oneclickvirt-ipv6"
if setup_ipv6_cron; then
    echo 'FAIL: symlink cron directory was accepted' >&2
    exit 1
fi

export OCV_IPV6_CRON_DIR="$TMP_DIR/cron.d"
ln -s "$OCV_IPV6_CRON_FILE" "$TMP_DIR/cron-file-symlink"
export OCV_IPV6_CRON_FILE="$TMP_DIR/cron-file-symlink"
if setup_ipv6_cron; then
    echo 'FAIL: symlink cron file was accepted' >&2
    exit 1
fi

export OCV_IPV6_CRON_FILE="$TMP_DIR/cron.d/oneclickvirt-ipv6"
mkdir -p "$TMP_DIR/lock-target"
ln -s "$TMP_DIR/lock-target" "$TMP_DIR/lock-symlink"
export OCV_IPV6_CRON_LOCK="$TMP_DIR/lock-symlink/ipv6-cron.lock"
if setup_ipv6_cron; then
    echo 'FAIL: symlink lock directory was accepted' >&2
    exit 1
fi

printf 'ipv6 cron.d tests passed\n'
