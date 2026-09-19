#!/usr/bin/env bash
# Actual production control flow with injected firewalld API failures.
# No daemon, host firewall or production config is changed.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [ -f "$repo_root/scripts/incus_install.sh" ]; then
    runtime=incus
    entries=(incus_install.sh uninstall_incus.sh)
else
    runtime=lxd
    entries=(lxdinstall.sh lxduninstall.sh)
fi
mkdir -p "$test_dir/firewalld"
printf '%s\n' "oneclickvirt-$runtime-ipv4" >"$test_dir/firewalld/direct.xml"
load_function() {
    local definition
    definition=$(awk -v name="$2" '$0==name "() {" { active=1 } active {print} active && /^}$/ {exit}' "$repo_root/scripts/$1")
    [ -n "$definition" ] || fail "missing $2"
    definition="${definition//\/etc\/firewalld/$test_dir/firewalld}"
    eval "${definition//\/snap\/bin\/lxc/lxc}"
}
owned="0 -s 10.78.1.1/24 '!' -o ${runtime}br0 -m comment --comment oneclickvirt-${runtime}-ipv4 -j MASQUERADE"
foreign="0 -s 10.78.1.1/24 '!' -o ${runtime}br0 -m comment --comment oneclickvirt-${runtime}-ipv4-custom -j MASQUERADE"
calls="$test_dir/calls"
firewall-cmd() {
    case "$*" in
        --state) return "$mock_state_status" ;;
        '--permanent --direct --get-rules ipv4 nat POSTROUTING')
            printf '%s\n' "$mock_permanent_rules"; return "$mock_permanent_status" ;;
        '--direct --get-rules ipv4 nat POSTROUTING')
            printf '%s\n' "$mock_runtime_rules"; return "$mock_runtime_status" ;;
        "--permanent --get-zone-of-interface=${runtime}br0"|"--get-zone-of-interface=${runtime}br0")
            printf '%s\n' 'administrator-zone'; return 0 ;;
        *) printf '%s\n' "$*" >>"$calls"; return "$mock_mutation_status" ;;
    esac
}
firewall-offline-cmd() {
    case "$*" in
        '--direct --get-rules ipv4 nat POSTROUTING') printf '%s\n' "$mock_permanent_rules"; return "$mock_permanent_status" ;;
        *) printf 'offline %s\n' "$*" >>"$calls"; return "$mock_mutation_status" ;;
    esac
}
incus() {
    case "$*" in
        "network get ${runtime}br0 ipv4.nat") printf '%s\n' true ;;
        "network get ${runtime}br0 ipv4.address") printf '%s\n' 10.78.1.1/24 ;;
        *) fail "unexpected metadata request: $*" ;;
    esac
}
lxc() { incus "$@"; }
for entry in "${entries[@]}"; do
    fn="sync_${runtime}_firewalld_masquerade"
    load_function "$entry" "$fn"
    mock_state_status=0 mock_permanent_status=0 mock_runtime_status=0 mock_mutation_status=0
    mock_permanent_rules="$owned"$'\n'"$foreign" mock_runtime_rules="$mock_permanent_rules"
    : >"$calls"
    "$fn" 10.78.1.1/24
    [ ! -s "$calls" ] || fail "$entry repeated install mutated matching rules"
    "$fn"
    [ "$(wc -l <"$calls" | tr -d ' ')" -eq 2 ] || fail "$entry did not remove both scopes"
    if grep -Fq ipv4-custom "$calls"; then fail "$entry removed another owner's rule"; fi

    for error_kind in state permanent runtime; do
        mock_state_status=0 mock_permanent_status=0 mock_runtime_status=0
        case "$error_kind" in state) mock_state_status=36;; permanent) mock_permanent_status=41;; runtime) mock_runtime_status=42;; esac
        : >"$calls"
        if "$fn"; then fail "$entry ignored $error_kind API failure"; fi
        [ ! -s "$calls" ] || fail "$entry used incomplete/unavailable inventory"
    done
    mock_state_status=0 mock_permanent_status=0 mock_runtime_status=0 mock_mutation_status=43
    : >"$calls"
    if "$fn"; then fail "$entry ignored removal failure"; fi
    if "$fn" 10.79.1.1/24; then fail "$entry ignored add failure"; fi
    mock_mutation_status=0
    : >"$calls"
    for subnet in 999.1.1.1/24 10.78.1.1/0 10.78.1.1/33 '10.78.1.1/24; true'; do
        if "$fn" "$subnet"; then fail "$entry accepted invalid subnet"; fi
    done
    [ ! -s "$calls" ] || fail "$entry invalid metadata mutated policy"
    mock_state_status=252
    "$fn"
    [ "$(wc -l <"$calls" | tr -d ' ')" -eq 1 ] || fail "$entry offline cleanup not scoped"
    grep -q '^offline --direct --remove-rule' "$calls" || fail "$entry did not use offline API"
    : >"$calls"
    if "$fn" 10.78.1.1/24; then fail "$entry configured NAT while daemon stopped"; fi
    [ ! -s "$calls" ] || fail "$entry added offline NAT"
done
load_function "${entries[0]}" configure_firewalld_masquerade
mock_state_status=0 mock_permanent_status=0 mock_runtime_status=0 mock_mutation_status=0
: >"$calls"
configure_firewalld_masquerade
[ ! -s "$calls" ] || fail 'installer replaced administrator bridge zones or matching NAT'
printf 'PASS: %s firewalld idempotence, ownership, state/query/mutation errors and offline cleanup\n' "$runtime"
