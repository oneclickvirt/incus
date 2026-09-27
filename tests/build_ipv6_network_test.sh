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
printf '\033[36mPréfixe                  : 2001:db8:abcd::/64\033[0m\n'
STUB
cat >"$TMP_DIR/bin/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    '-j -6 addr show')
        if [[ "${INCUS_TEST_TUNNEL:-}" == 1 ]]; then
            printf '%s\n' '[{"ifname":"he-ipv6","addr_info":[{"family":"inet6","local":"2606:4700::1","prefixlen":64,"scope":"global"}]}]'
        elif [[ "${INCUS_TEST_SAME_INTERFACE:-}" == 1 ]]; then
            printf '\033[36m%s\033[0m\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":128,"scope":"global"},{"family":"inet6","local":"2a14:7c0:1002:10f8::2","prefixlen":38,"scope":"global"}]}]'
        elif [[ "${INCUS_TEST_DELEGATED:-}" == 1 ]]; then
            printf '\033[36m%s\033[0m\n' '[{"ifname":"vmbr0","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":128,"scope":"global"}]},{"ifname":"vmbr2","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":38,"scope":"global"}]}]'
        elif [[ "${INCUS_TEST_NO_LOCAL_IPV6:-}" == 1 ]]; then
            printf '%s\n' '[{"ifname":"eth0","addr_info":[]}]'
        elif [[ "${INCUS_TEST_LOCAL_ULA_FIRST:-}" == 1 ]]; then
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"fd42::1","prefixlen":64,"scope":"global"},{"family":"inet6","local":"2606:4700::1111","prefixlen":64,"scope":"global"}]}]'
        else
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2606:4700::1111","prefixlen":64,"scope":"global"}]}]'
        fi
        exit 0
        ;;
    '-j -6 route show default')
        if [[ -n "${INCUS_TEST_ROUTE_STATE:-}" && -f "$INCUS_TEST_ROUTE_STATE" ]]; then
            printf '%s\n' '[{"dst":"default","dev":"eth0","gateway":"2606:4700::1"}]'
        else
            printf '%s\n' '[]'
        fi
        exit 0
        ;;
    '-j -6 neigh show dev eth0')
        printf '%s\n' '[{"dst":"2606:4700::1","router":true}]'
        exit 0
        ;;
    '-j -6 route show table all')
        printf '%s\n' '[]'
        exit 0
        ;;
esac
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

gateway_rows=$(printf '\033[35mRouteur : fe80::1\033[0m\n路由器：fe80::2\nRouter: fe80::3\n' | rdisc6_router_addresses)
[[ "$gateway_rows" == $'fe80::1\nfe80::2\nfe80::3' ]] || fail "localized router-advertisement gateways: $gateway_rows"

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
    "-j -6 addr show")
        printf '\033[36m%s\033[0m\n' '[{"ifname":"vmbr0","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":128,"scope":"global"}]},{"ifname":"vmbr2","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":38,"scope":"global"}]}]'
        ;;
    *)
        command ip "$@"
        ;;
    esac
}
export INCUS_TEST_DELEGATED=1
check_ipv6 >/dev/null || fail 'delegated /38 was not accepted'
assert_eq '2a14:7c0:1002:10f8::1' "$IPV6" 'delegated /38 wins over host /128'
assert_eq vmbr2 "$(ipv6_uplink_interface "$IPV6")" 'delegated bridge wins over host /128'
unset INCUS_TEST_DELEGATED
unset -f ip

# A host-only /128 and a delegated prefix can live on the same interface.
# The wider prefix must win even when the preferred probe address is the /128.
export INCUS_TEST_SAME_INTERFACE=1
check_ipv6 >/dev/null || fail 'same-interface delegated prefix was not accepted'
assert_eq eth0 "$(ipv6_uplink_interface "$IPV6")" 'same-interface uplink selection'
assert_eq '2a14:7c0:1002:10f8::2/38' "$(ipv6_uplink_cidr eth0 "$IPV6")" 'same-interface wider prefix selection'
unset INCUS_TEST_SAME_INTERFACE

# A public address without a default route may recover through a real router
# neighbor, but the route must be retained only after the external probe works.
route_state="$TMP_DIR/route-state"
export INCUS_TEST_ROUTE_STATE="$route_state"
ip() {
    case "$*" in
    "-j -6 route show default")
        [ -f "$route_state" ] && printf '%s\n' '[{"dst":"default","dev":"eth0","gateway":"2606:4700::1"}]' || printf '%s\n' '[]'
        ;;
    "-j -6 neigh show dev eth0") printf '%s\n' '[{"dst":"2606:4700::1","router":true}]' ;;
    "route show default") printf '%s\n' 'default via 2606:4700::1 dev eth0' ;;
    "-6 neigh show dev eth0") printf '%s\n' '2606:4700::1 dev eth0 lladdr 00:11:22:33:44:55 router REACHABLE' ;;
    "-6 route replace default via 2606:4700::1 dev eth0 metric 4096") printf '%s\n' ok >"$route_state" ;;
    "-6 route show default dev eth0") [ -f "$route_state" ] && printf '%s\n' 'default via 2606:4700::1 dev eth0 metric 4096' ;;
    "-6 route del default via 2606:4700::1 dev eth0 metric 4096"|"-6 route del default dev eth0 metric 4096") rm -f "$route_state" ;;
    *) command ip "$@" ;;
    esac
}
curl() { return 0; }
ensure_ipv6_default_route || fail "IPv6 default route was not recovered from a verified router neighbor"
[ -f "$route_state" ] || fail "verified IPv6 route was not retained"
rm -f "$route_state"
curl() { return 1; }
if ensure_ipv6_default_route; then
    fail "IPv6 route probe failure was accepted"
fi
[ ! -e "$route_state" ] || fail "unverified IPv6 route was not rolled back"
unset -f ip curl
unset INCUS_TEST_ROUTE_STATE

# shellcheck disable=SC2016 # The literal is the source-code contract under test.
if ! grep -Fq 'net.ipv6.conf.${ipv6_network_name}.accept_ra=2' "$ROOT_DIR/scripts/build_ipv6_network.sh"; then
    fail "IPv6 forwarding must preserve router advertisements on the Incus uplink"
fi
# shellcheck disable=SC2016 # The literal is the source-code contract under test.
if ! grep -Fq 'net.ipv6.conf.all.proxy_ndp=1' "$ROOT_DIR/scripts/build_ipv6_network.sh"; then
    fail "Incus routed NICs require global NDP proxying"
fi
if ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$ROOT_DIR/scripts/build_ipv6_network.sh" ||
   ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$ROOT_DIR/scripts/buildct.sh" ||
   ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$ROOT_DIR/scripts/buildvm.sh"; then
    fail "IPv6 keepalive jobs must force IPv6 and fail closed on probe errors"
fi

# Reproduce the reported shape: cached terminal text, ANSI bytes, and the
# scalar on separate lines. It must be rejected rather than whitespace-joined.
printf '\033[36mAttempting to get real IPv6 prefix...\033[0m\n64\n' >"$TMP_DIR/state/incus_ipv6_real_prefixlen"
if ! prefix=$(get_real_ipv6_prefixlen_from_router eth0 48 2>"$TMP_DIR/diagnostics"); then
    cat "$TMP_DIR/diagnostics" >&2
    fail "router prefix detection failed"
fi
[ "$prefix" = "48" ] || fail "polluted cache changed the host /48 to '$prefix'"
[ "$(cat "$TMP_DIR/state/incus_ipv6_real_prefixlen")" = "48" ] || fail "host /48 was not persisted atomically"
grep -q "Attempting to get real IPv6 prefix" "$TMP_DIR/diagnostics" || fail "diagnostics were not sent to stderr"

prefix=$(get_real_ipv6_prefixlen_from_router eth0 48 2>"$TMP_DIR/cached-diagnostics") || fail "clean cache read failed"
[ "$prefix" = "48" ] || fail "clean cache produced '$prefix'"
[ ! -s "$TMP_DIR/cached-diagnostics" ] || fail "clean cache unexpectedly emitted diagnostics"

for current in 38 80 128; do
    prefix=$(get_real_ipv6_prefixlen_from_router eth0 "$current" 2>"$TMP_DIR/cached-diagnostics") || fail "host /$current prefix refresh failed"
    [ "$prefix" = "$current" ] || fail "RA /64 or stale cache changed host /$current to /$prefix"
    [ "$(cat "$TMP_DIR/state/incus_ipv6_real_prefixlen")" = "$current" ] || fail "host /$current was not cached"
done
rm -f "$TMP_DIR/state/incus_ipv6_real_prefixlen"
prefix=$(get_real_ipv6_prefixlen_from_router eth0 invalid 2>"$TMP_DIR/diagnostics") || fail 'RA fallback with unknown interface prefix failed'
[ "$prefix" = "64" ] || fail "unknown interface prefix did not fall back to RA /64: $prefix"

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

# A real Incus command failure must not be recorded as a successful NAT66
# fallback.  This is intentionally separate from the no-command unit fixture
# above, which only tests state bookkeeping.
incus() {
    case "$1 $2 $3 $4 $5" in
        "config device get"*) return 1 ;;
        "network get"*) return 1 ;;
        "network set"*) return 1 ;;
        *) return 1 ;;
    esac
}
CONTAINER_NAME=incus-fallback-failure
if configure_ipv6_nat66_fallback >/dev/null 2>&1; then
    fail "Incus NAT66 command failure was hidden"
fi
unset CONTAINER_NAME
unset -f incus

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
export INCUS_TEST_TUNNEL=1
assert_eq "he-ipv6" "$(ipv6_uplink_interface)" "explicit tunnel uplink"
assert_eq "2606:4700::1/64" "$(ipv6_uplink_cidr he-ipv6 2606:4700::1)" "tunnel address selection"
unset INCUS_TEST_TUNNEL
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

# The routed device path must be additive and idempotent. An existing
# bridged NIC (or non-NIC device) must never be removed just to make room for
# eth1, while a valid routed NIC is updated in place.
device_calls="$TMP_DIR/device-calls"
INCUS_FAKE_DEVICE=missing
incus() {
    printf '%s\n' "$*" >>"$device_calls"
    if [ "$1" = config ] && [ "$2" = device ] && [ "$3" = get ]; then
        case "$6" in
            type)
                [ "$INCUS_FAKE_DEVICE" != missing ] || return 1
                if [ "$INCUS_FAKE_DEVICE" = nonnic ]; then
                    printf '%s\n' disk
                else
                    printf '%s\n' nic
                fi
                ;;
            nictype)
                if [ "$INCUS_FAKE_DEVICE" = routed ] || [ "$INCUS_FAKE_DEVICE" = set-fails ]; then
                    printf '%s\n' routed
                elif [ "$INCUS_FAKE_DEVICE" = bridged ]; then
                    printf '%s\n' bridged
                else
                    return 1
                fi
                ;;
            *) return 1 ;;
        esac
        return 0
    fi
    if [ "$1" = config ] && [ "$2" = device ] && [ "$3" = set ]; then
        [ "$INCUS_FAKE_DEVICE" != set-fails ] || return 1
        return 0
    fi
    if [ "$1" = config ] && [ "$2" = device ] && [ "$3" = add ]; then
        [ "$INCUS_FAKE_DEVICE" = missing ] || return 1
        return 0
    fi
    if [ "$1" = config ] && [ "$2" = device ] && [ "$3" = override ]; then
        [ "$INCUS_FAKE_DEVICE" = set-fails ] || return 1
        return 0
    fi
    return 0
}

: >"$device_calls"
configure_routed_ipv6_device testct eth0 2001:db8::10 || fail "new routed eth1 was not added"
grep -Fq 'config device add testct eth1 nic nictype=routed parent=eth0 ipv6.address=2001:db8::10 ipv6.gateway=auto' "$device_calls" || fail "new routed eth1 did not set ipv6.gateway=auto"
if grep -Fq 'config device remove' "$device_calls"; then
    fail "new routed eth1 unexpectedly removed a device"
fi

: >"$device_calls"
INCUS_FAKE_DEVICE=routed
configure_routed_ipv6_device testct eth0 2001:db8::11 || fail "existing routed eth1 was not updated"
grep -Fq 'config device set testct eth1 ipv6.gateway auto' "$device_calls" || fail "existing routed eth1 did not receive ipv6.gateway=auto"
if grep -Fq 'config device remove' "$device_calls" || grep -Fq 'config device add' "$device_calls"; then
    fail "existing routed eth1 was removed/replaced"
fi

: >"$device_calls"
INCUS_FAKE_DEVICE=bridged
if configure_routed_ipv6_device testct eth0 2001:db8::12; then
    fail "bridged eth1 was silently overwritten"
fi
if grep -Fq 'config device remove' "$device_calls" || grep -Fq 'config device add' "$device_calls" || grep -Fq 'config device set' "$device_calls"; then
    fail "bridged eth1 was modified after validation failure"
fi

: >"$device_calls"
INCUS_FAKE_DEVICE=nonnic
if configure_routed_ipv6_device testct eth0 2001:db8::13; then
    fail "non-NIC eth1 was silently overwritten"
fi

: >"$device_calls"
INCUS_FAKE_DEVICE=set-fails
configure_routed_ipv6_device testct eth0 2001:db8::14 || fail "profile device override failed"
grep -Fq 'config device override testct eth1 nictype=routed parent=eth0 ipv6.address=2001:db8::14 ipv6.gateway=auto' "$device_calls" || fail "profile device update did not use a safe override"
if grep -Fq 'config device remove' "$device_calls"; then
    fail "failed profile update removed eth1"
fi
unset -f incus

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
# The JSON parser itself is covered by add_ipv6_restore_test.sh. This fixture
# supplies an empty interface so the legacy restore behavior can be checked.
restore_ipv6_json_rows() { [ "$1" = addresses ]; }
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
unset -f restore_ipv6_json_rows
unset -f ip

# Readiness is idempotent: an already running instance must not be treated as
# a failed `incus start`, while a stopped instance is started and rechecked.
start_calls="$TMP_DIR/start-calls"
stopped_started=false
incus() {
    case "${1:-} ${2:-}" in
        "list running") printf '%s\n' '[{"name":"running","status_code":103}]' ;;
        "list stopped")
            if [ "$stopped_started" = true ]; then printf '%s\n' '[{"name":"stopped","status_code":103}]'; else printf '%s\n' '[{"name":"stopped","status_code":102}]'; fi
            ;;
        "start stopped") stopped_started=true; printf '%s\n' "$*" >>"$start_calls" ;;
        *) return 1 ;;
    esac
}
wait_for_container_running running || fail "already running container was rejected"
if [ -s "$start_calls" ]; then
    fail "already running container was started again"
fi
wait_for_container_running stopped || fail "stopped container was not started"
grep -Fxq 'start stopped' "$start_calls" || fail "stopped container start was not recorded"
unset -f incus

container_state=RUNNING
incus() {
    case "${1:-} ${2:-}" in
        "list stoptest")
            if [ "$container_state" = STOPPED ]; then
                printf '%s\n' '[{"name":"stoptest","status_code":102}]'
            else
                printf '%s\n' '[{"name":"stoptest","status_code":103}]'
            fi
            ;;
        "stop stoptest") container_state=STOPPED ;;
        *) return 1 ;;
    esac
}
wait_for_container_stopped stoptest || fail "running container was not stopped"
[ "$container_state" = STOPPED ] || fail "stop readiness returned before STOPPED"
unset -f incus

echo "build_ipv6_network tests passed"
