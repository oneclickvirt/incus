#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
buildct="$repo_root/scripts/buildct.sh"
buildvm="$repo_root/scripts/buildvm.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/incus-network-mode.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

extract_function() {
    awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$buildct"
}

eval "$(extract_function normalize_network_type)"
eval "$(extract_function require_public_ipv6_result)"

check_mode() {
    local requested="$1" legacy="$2" expected_type="$3" expected_ipv6="$4"
    OCV_NETWORK_TYPE="$requested"
    enable_ipv6="$legacy"
    normalize_network_type
    [ "$network_type" = "$expected_type" ]
    [ "$enable_ipv6" = "$expected_ipv6" ]
}

check_mode nat_ipv4 Y nat_ipv4 n
check_mode nat_ipv4_ipv6 N nat_ipv4_ipv6 y
check_mode ipv6_only N ipv6_only y
check_mode '' Y nat_ipv4_ipv6 y
check_mode '' N nat_ipv4 n
if OCV_NETWORK_TYPE=invalid enable_ipv6=n normalize_network_type >/dev/null 2>&1; then
    echo 'invalid network mode was accepted' >&2
    exit 1
fi

(
    cd "$test_dir"
    name=fixture
    OCV_REQUIRE_PUBLIC_IPV6=yes
    if require_public_ipv6_result >/dev/null 2>&1; then
        echo 'missing public IPv6 record was accepted' >&2
        exit 1
    fi
    printf '%s\n' 'fd00::10' >fixture_v6
    if require_public_ipv6_result >/dev/null 2>&1; then
        echo 'ULA was accepted as public IPv6' >&2
        exit 1
    fi
    printf '%s\n' '2001:4860:4860::8888' >fixture_v6
    require_public_ipv6_result
)

grep -Fq 'if [ "$network_type" = "ipv6_only" ]; then' "$buildct"
grep -Fq 'incus config device add "$name" eth0 none' "$buildct"
grep -Fq 'incus config device set "$name" eth1 limits.egress' "$buildct"
grep -Fq 'nameserver 2606:4700:4700::1111' "$buildct"
grep -Fq 'require_public_ipv6_result || return 1' "$buildct"
grep -Fq 'wait_for_instance_ssh_ready || return 1' "$buildct"
grep -Fq 'wait_for_instance_ssh_ready || return 1' "$buildvm"
grep -Fq 'prepare_vm_ipv6_network || return 1' "$buildvm"
grep -Fq 'OCV_BUILDVM_DIR=' "$buildvm"
grep -Fq 'script_path="$OCV_BUILDVM_DIR"' "$buildvm"
setup_vm_block=$(sed -n '/^setup_vm() {/,/^}/p' "$buildvm")
prepare_line=$(printf '%s\n' "$setup_vm_block" | grep -nF 'prepare_vm_ipv6_network || return 1' | cut -d: -f1)
start_line=$(printf '%s\n' "$setup_vm_block" | grep -nF 'incus start "$name"' | cut -d: -f1)
[ -n "$prepare_line" ] && [ -n "$start_line" ] && [ "$prepare_line" -lt "$start_line" ] || {
    echo 'VM IPv6 bootstrap must precede its first start' >&2
    exit 1
}

(
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/incus-helper-refresh.XXXXXX")
    trap 'rm -rf -- "$work_dir"' EXIT
    cd "$work_dir"
    export ONECLICKVIRT_TESTING=1
    # shellcheck disable=SC1090
    source "$buildvm"
    refresh_ipv6_helper "$work_dir/helper.sh"
    cmp -s "$repo_root/scripts/build_ipv6_network.sh" "$work_dir/helper.sh"
)
echo 'PASS: Incus shell network modes fail closed and mask inherited IPv4 in IPv6-only mode'
