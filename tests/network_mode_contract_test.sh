#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
buildct="$repo_root/scripts/buildct.sh"
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
echo 'PASS: Incus shell network modes fail closed and mask inherited IPv4 in IPv6-only mode'
