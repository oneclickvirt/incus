#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [ "$expected" = "$actual" ] || fail "$label: expected [$expected], got [$actual]"
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
cat >"$TMP_DIR/bin/ip" <<'STUB'
#!/usr/bin/env bash
if [[ "${INCUS_TEST_NO_LOCAL_IPV6:-}" == "1" ]]; then
    exit 0
fi
if [[ "${INCUS_TEST_LOCAL_ULA_FIRST:-}" == "1" ]]; then
    printf '2: eth0    inet6 fd42::1/64 scope global\n'
fi
printf '2: eth0    inet6 2606:4700::1111/64 scope global\n'
STUB
cat >"$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'external IPv6 lookup invoked\n' >"${INCUS_TEST_CURL_MARKER:?}"
exit 1
STUB
chmod +x "$TMP_DIR/bin/timeout" "$TMP_DIR/bin/rdisc6" "$TMP_DIR/bin/ip" "$TMP_DIR/bin/curl"

export PATH="$TMP_DIR/bin:$PATH"
export INCUS_STATE_DIR="$TMP_DIR/state"
export ONECLICKVIRT_TESTING=1
# shellcheck disable=SC1091 # The test sources the repository script through a computed path.
. "$ROOT_DIR/scripts/build_ipv6_network.sh"

# shellcheck disable=SC2034 # Read by functions loaded from build_ipv6_network.sh.
GREP_EXTENDED=-E
# shellcheck disable=SC2034 # Read by functions loaded from build_ipv6_network.sh.
GREP_PERL_SUPPORT=false

export INCUS_TEST_CURL_MARKER="$TMP_DIR/curl-called"
export INCUS_TEST_LOCAL_ULA_FIRST=1
check_ipv6 >/dev/null || fail "locally bound IPv6 was not accepted"
[ "$IPV6" = "2606:4700::1111" ] || fail "local IPv6 = '$IPV6'"
[ "$(cat "$TMP_DIR/state/incus_check_ipv6")" = "2606:4700::1111" ] || fail "local IPv6 was not persisted"
[ ! -e "$INCUS_TEST_CURL_MARKER" ] || fail "check_ipv6 used an external address service"
unset INCUS_TEST_LOCAL_ULA_FIRST
if is_private_ipv6 "2606:4700::1111"; then
    fail "a public 2606 IPv6 address was classified as private"
fi
if ! is_private_ipv6 "2001::"; then
    fail "the compressed Teredo prefix was accepted as public"
fi
if ! is_private_ipv6 "fc12::1" || ! is_private_ipv6 "fe90::1" || ! is_private_ipv6 "fec0::1" || ! is_private_ipv6 "ff02::1" || ! is_private_ipv6 "2001:0000::1" || ! is_private_ipv6 "2001:0010::1"; then
    fail "local, site-local, or multicast IPv6 was accepted as public"
fi
export INCUS_TEST_NO_LOCAL_IPV6=1
if check_ipv6 >/dev/null 2>&1; then
    fail "check_ipv6 accepted a host without a locally bound public IPv6 address"
fi
[ ! -e "$INCUS_TEST_CURL_MARKER" ] || fail "missing local IPv6 triggered an external lookup"
unset INCUS_TEST_NO_LOCAL_IPV6

# A host /128 may duplicate the address on a delegated bridge. The selector
# must retain the bridge's /38 instead of treating the first /128 as a pool.
# shellcheck disable=SC2329 # Called indirectly by the sourced network helpers.
ip() {
    case "$*" in
    "-o -6 addr show scope global")
        printf '%s\n' \
            '3: vmbr0    inet6 2a14:7c0:1002:10f8::1/128 scope global' \
            '5: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
        ;;
    "-o -6 addr show dev vmbr2 scope global")
        printf '%s\n' '5: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
        ;;
    *)
        command ip "$@"
        ;;
    esac
}
check_ipv6 >/dev/null || fail 'delegated /38 was not accepted'
assert_eq '2a14:7c0:1002:10f8::1' "$IPV6" 'delegated /38 wins over host /128'
assert_eq vmbr2 "$(ipv6_uplink_interface "$IPV6")" 'delegated bridge wins over host /128'
unset -f ip

# shellcheck disable=SC2016 # The literal is the source-code contract under test.
if ! grep -Fq 'net.ipv6.conf.${ipv6_network_name}.accept_ra=2' "$ROOT_DIR/scripts/build_ipv6_network.sh"; then
    fail "IPv6 forwarding must preserve router advertisements on the Incus uplink"
fi
# shellcheck disable=SC2016 # The literal is the source-code contract under test.
if grep -Fq 'net.ipv6.conf.all.proxy_ndp=1' "$ROOT_DIR/scripts/build_ipv6_network.sh"; then
    fail "Incus must not enable NDP proxying globally"
fi

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

# Allocation classification must preserve usable routed prefixes while
# refusing to manufacture a pool from a host-only /128.
assert_eq "2a14:7c0:1000::/38" "$(ipv6_allocation_network '2a14:7c0:1002:10f8::1/38')" "normalize non-nibble routed prefix"
assert_eq "2606:4700::/127" "$(ipv6_allocation_network '2606:4700::1/127')" "retain /127 routed prefix"
assert_eq "2606:4700::/64" "$(ipv6_allocation_network '2606:4700::1/64')" "retain SLAAC /64 shape"
if ipv6_allocation_network '2606:4700::1/128' >/dev/null; then
    fail "/128 was accepted as an IPv6 allocation pool"
fi
if ipv6_pool_has_extra_address '2606:4700::1/128' '2606:4700::1'; then
    fail "/128 was reported to have an extra address"
fi
if ! ipv6_pool_has_extra_address '2606:4700::/127' '2606:4700::'; then
    fail "/127 was rejected despite having one remaining address"
fi
export INCUS_IPV6_ROUTED_PREFIX='2a14:7c0:1002:2000::/64'
assert_eq "2a14:7c0:1002:2000::/64" "$(ipv6_allocation_network '2606:4700::1/128')" "explicit routed prefix overrides host /128"
unset INCUS_IPV6_ROUTED_PREFIX

printf '%s\n' routed >"$TMP_DIR/state/incus_ipv6_mode"
configure_ipv6_nat66_fallback >/dev/null
assert_eq routed "$(cat "$TMP_DIR/state/incus_ipv6_mode")" "fallback preserves existing routed mode"
rm -f "$TMP_DIR/state/incus_ipv6_mode"
configure_ipv6_nat66_fallback >/dev/null
assert_eq nat66 "$(cat "$TMP_DIR/state/incus_ipv6_mode")" "fallback records NAT66 mode"

# Explicit tunnel selection must win over a physical-interface fallback.
# shellcheck disable=SC2329 # Called indirectly by the sourced network helpers.
ip() {
    case "$*" in
    "-o -6 addr show dev he-ipv6 scope global")
        printf '%s\n' '7: he-ipv6    inet6 2606:4700::1/64 scope global'
        ;;
    *)
        command ip "$@"
        ;;
    esac
}
export INCUS_IPV6_UPLINK=he-ipv6
assert_eq "he-ipv6" "$(ipv6_uplink_interface)" "explicit tunnel uplink"
assert_eq "2606:4700::1/64" "$(ipv6_uplink_cidr he-ipv6 2606:4700::1)" "tunnel address selection"
unset INCUS_IPV6_UPLINK
unset -f ip

# Migrate the old generated link-local deletion helper without touching an
# unrelated administrator script.
legacy_cleanup="$TMP_DIR/remove_route.sh"
printf '%s\n' '#!/bin/bash' 'ip addr del fe80::1/64 dev eth0' >"$legacy_cleanup"
export INCUS_LEGACY_FE80_CLEANUP="$legacy_cleanup"
disable_legacy_link_local_cleanup
[ ! -e "$legacy_cleanup" ] || fail "legacy fe80 cleanup helper was left active"
unset INCUS_LEGACY_FE80_CLEANUP

admin_cleanup="$TMP_DIR/admin-route.sh"
printf '%s\n' '#!/bin/bash' 'ip addr del fe80::2/64 dev eth0' 'echo keep-this-script' >"$admin_cleanup"
export INCUS_LEGACY_FE80_CLEANUP="$admin_cleanup"
disable_legacy_link_local_cleanup
[ -e "$admin_cleanup" ] || fail "administrator fe80 script was removed"
unset INCUS_LEGACY_FE80_CLEANUP

if grep -Eq 'ip[[:space:]]+addr[[:space:]]+del[[:space:]]+fe80:' "$ROOT_DIR/scripts/build_ipv6_network.sh"; then
    fail "build script still deletes link-local IPv6 addresses"
fi

# Reboot restoration consumes the exact prefix/interface metadata and must not
# invent a /64 or bind ULA/documentation addresses as public mappings.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/add-ipv6.sh"

# A persisted mapping must remain bound to its original routed bridge after a
# reboot, even if the physical NIC is the current default-route interface.
printf '%s\n' vmbr2 >"$TMP_DIR/state/incus_ipv6_mapping_interface"
# shellcheck disable=SC2329 # Called indirectly by get_interface.
ip() {
    case "$*" in
    "link show dev vmbr2"|"link show dev eth0") return 0 ;;
    "-6 route show default") printf '%s\n' 'default via fe80::1 dev eth0 proto ra metric 1024' ;;
    *) command ip "$@" ;;
    esac
}
assert_eq vmbr2 "$(get_interface)" "saved routed bridge wins over default route"
rm -f "$TMP_DIR/state/incus_ipv6_mapping_interface"
assert_eq eth0 "$(get_interface)" "IPv6 default-route fallback"
unset -f ip

printf '%s\n' 128 >"$TMP_DIR/state/incus_ipv6_mapping_prefix_len"
assert_eq 128 "$(get_host_ipv6_prefixlen eth0)" "strict persisted /128 prefix"
printf '%s\n' 64 128 >"$TMP_DIR/state/incus_ipv6_mapping_prefix_len"
if read_strict_prefix_len "$TMP_DIR/state/incus_ipv6_mapping_prefix_len" >/dev/null; then
    fail "multiline mapping prefix was accepted"
fi
restore_calls="$TMP_DIR/restore-calls"
# shellcheck disable=SC2329 # Called indirectly by restore_address.
ip() {
    case "$*" in
    "-6 addr show dev eth0") return 1 ;;
    "-6 addr replace "*) printf '%s\n' "$*" >>"$restore_calls" ;;
    *) command ip "$@" ;;
    esac
}
restore_address 'fd42::1' eth0 64
[ ! -s "$restore_calls" ] || fail "ULA was restored as a public address"
restore_address '2606:4700::1' eth0 128
grep -Fq -- '-6 addr replace 2606:4700::1/128 dev eth0' "$restore_calls" || fail "global /128 mapping was not restored"
unset -f ip

echo "build_ipv6_network tests passed"
