#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2329
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
for entry in "${entries[@]}"; do
    for operation in masquerade persistence; do
        function_name="remove_${runtime}_iptables_$operation"
        definition=$(awk -v name="$function_name" '$0==name "() {" { active=1 } active {print} active && /^}$/ {exit}' "$repo_root/scripts/$entry")
        [ -n "$definition" ] || fail "missing $function_name"
        eval "$definition"
    done
    owned_rule="-A POSTROUTING -s 10.78.1.0/24 ! -o ${runtime}br0 -m comment --comment oneclickvirt-${runtime}-ipv4 -j MASQUERADE"
    unrelated="-A POSTROUTING -s 198.18.0.0/24 -m comment --comment oneclickvirt-${runtime}-ipv4-custom -j MASQUERADE"
    inventory_status=0 delete_status=0 calls=()
    mock_backend() {
        if [ "$*" = '-w -t nat -S POSTROUTING' ]; then
            printf '%s\n' "$owned_rule" "$unrelated"
            return "$inventory_status"
        fi
        calls+=("$*")
        return "$delete_status"
    }
    "remove_${runtime}_iptables_masquerade" mock_backend
    [ "${#calls[@]}" -eq 1 ] || fail "$entry removed foreign rule"
    inventory_status=41 calls=()
    if "remove_${runtime}_iptables_masquerade" mock_backend; then fail "$entry ignored inventory error"; fi
    [ "${#calls[@]}" -eq 0 ] || fail "$entry used incomplete inventory"
    inventory_status=0 delete_status=42
    if "remove_${runtime}_iptables_masquerade" mock_backend; then fail "$entry ignored delete error"; fi

    printf '%s\n' '*nat' ':POSTROUTING ACCEPT [0:0]' "$owned_rule" "$unrelated" '-A POSTROUTING -j MASQUERADE' COMMIT >"$test_dir/policy"
    cp "$test_dir/policy" "$test_dir/before"
    (
        awk() { return 43; }
        if "remove_${runtime}_iptables_persistence" "$test_dir/policy"; then fail "$entry hid filter failure"; fi
    )
    cmp "$test_dir/policy" "$test_dir/before" || fail "$entry truncated policy on filter failure"
    (
        mv() { return 44; }
        if "remove_${runtime}_iptables_persistence" "$test_dir/policy"; then fail "$entry hid rename failure"; fi
    )
    cmp "$test_dir/policy" "$test_dir/before" || fail "$entry changed policy on rename failure"
    "remove_${runtime}_iptables_persistence" "$test_dir/policy"
    grep -Fxq -- "$unrelated" "$test_dir/policy" || fail "$entry removed administrator policy"
    grep -Fxq -- '-A POSTROUTING -j MASQUERADE' "$test_dir/policy" || fail "$entry removed ambiguous legacy rule"
    if grep -Fxq -- "$owned_rule" "$test_dir/policy"; then fail "$entry retained owned rule"; fi
    cp "$test_dir/policy" "$test_dir/before"
    "remove_${runtime}_iptables_persistence" "$test_dir/policy"
    cmp "$test_dir/policy" "$test_dir/before" || fail "$entry cleanup not idempotent"
done
printf 'PASS: %s install/uninstall NAT inventory, delete and persistent-write failures\n' "$runtime"
