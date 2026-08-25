#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
cat >"$TMP_DIR/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB
cat >"$TMP_DIR/bin/rdisc6" <<'STUB'
#!/usr/bin/env bash
printf 'Prefix                   : 2001:db8:abcd::/64\n'
STUB
chmod +x "$TMP_DIR/bin/timeout" "$TMP_DIR/bin/rdisc6"

export PATH="$TMP_DIR/bin:$PATH"
export INCUS_STATE_DIR="$TMP_DIR/state"
export ONECLICKVIRT_TESTING=1
# shellcheck source=../scripts/build_ipv6_network.sh
. "$ROOT_DIR/scripts/build_ipv6_network.sh"

GREP_EXTENDED=-E
GREP_PERL_SUPPORT=false

# Reproduce the reported shape: cached terminal text, ANSI bytes, and the
# scalar on separate lines. It must be rejected rather than whitespace-joined.
printf '\033[36mAttempting to get real IPv6 prefix...\033[0m\n64\n' >"$TMP_DIR/state/incus_ipv6_real_prefixlen"
if ! prefix=$(get_real_ipv6_prefixlen_from_router eth0 48 2>"$TMP_DIR/diagnostics"); then
    cat "$TMP_DIR/diagnostics" >&2
    fail "router prefix detection failed"
fi
[ "$prefix" = "64" ] || fail "polluted cache produced '$prefix', want 64"
[ "$(cat "$TMP_DIR/state/incus_ipv6_real_prefixlen")" = "64" ] || fail "clean prefix was not persisted atomically"
grep -q "Attempting to get real IPv6 prefix" "$TMP_DIR/diagnostics" || fail "diagnostics were not sent to stderr"

prefix=$(get_real_ipv6_prefixlen_from_router eth0 48 2>"$TMP_DIR/cached-diagnostics") || fail "clean cache read failed"
[ "$prefix" = "64" ] || fail "clean cache produced '$prefix'"
[ ! -s "$TMP_DIR/cached-diagnostics" ] || fail "clean cache unexpectedly emitted diagnostics"

printf '2001:db8::10\n2001:db8::11\n' >"$TMP_DIR/state/incus_check_ipv6"
if read_strict_ipv6_file "$TMP_DIR/state/incus_check_ipv6" >/dev/null 2>&1; then
    fail "multiline IPv6 cache was accepted"
fi
if normalize_ipv6_address $'2001:db8::10\n\033[32mready' >/dev/null 2>&1; then
    fail "ANSI/multiline IPv6 value was accepted"
fi

network=$(get_host_ipv6_prefix "2001:db8:abcd:1234::f1/120" 2>"$TMP_DIR/network-diagnostics") || fail "CIDR normalization failed"
[ "$network" = "2001:db8:abcd:1234::/120" ] || fail "network = '$network'"
grep -q "IPv6 subnet" "$TMP_DIR/network-diagnostics" || fail "network diagnostics were not sent to stderr"

mapfile -t candidates_120 < <(generate_ipv6_candidates "2001:db8:abcd:1234::/120" 3)
[ "${candidates_120[*]}" = "2001:db8:abcd:1234::3 2001:db8:abcd:1234::4 2001:db8:abcd:1234::5" ] ||
    fail "/120 candidates = '${candidates_120[*]}'"

mapfile -t candidates_127 < <(generate_ipv6_candidates "2001:db8::/127" 10)
[ "${candidates_127[*]}" = "2001:db8:: 2001:db8::1" ] || fail "/127 candidates = '${candidates_127[*]}'"

mapfile -t candidates_128 < <(generate_ipv6_candidates "2001:db8::9/128" 10)
[ "${candidates_128[*]}" = "2001:db8::9" ] || fail "/128 candidates = '${candidates_128[*]}'"

echo "build_ipv6_network tests passed"
