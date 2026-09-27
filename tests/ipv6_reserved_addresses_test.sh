#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/build_ipv6_network.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/incus-reserved-ipv6.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

extract_function() {
    awk -v name="$1" '$0 == name "() {" {printing=1} printing {print} printing && /^}$/ {exit}' "$installer"
}
eval "$(extract_function generate_ipv6_candidates)"

cat >"$test_dir/ip" <<'EOF'
#!/bin/sh
case "$*" in
    '-j -6 addr show')
        if [ "${IP_TEST_SCENARIO:-}" = malformed ]; then
            printf '\033[31mAdresse ungültig\033[0m\n'
        else
            printf '\033[36m[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"%s"}]}]\033[0m\n' "$IP_TEST_HOST"
        fi
        ;;
    '-j -6 route show table all')
        if [ "${IP_TEST_MULTIPATH:-}" = 1 ]; then
            printf '\033[36m[{"dst":"default","nexthops":[{"gateway":"2001:db8::3","dev":"eth0"}],"multipath":[{"gateway":"2001:db8::4","dev":"eth1"}]},{"type":"local","dst":"local","dev":"lo"},{"dst":"%s/128","dev":"eth1"}]\033[0m\n' "$IP_TEST_ROUTE"
        else
            printf '\033[36m[{"dst":"default","gateway":"%s"},{"type":"multicast","dst":"multicast","dev":"lo"},{"dst":"%s/128","dev":"eth1"}]\033[0m\n' "$IP_TEST_GATEWAY" "$IP_TEST_ROUTE"
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "$test_dir/ip"
export PATH="$test_dir:$PATH"

export IP_TEST_HOST=2001:db8::1 IP_TEST_GATEWAY=2001:db8::2 IP_TEST_ROUTE=2001:db8::3
result=$(generate_ipv6_candidates '2001:db8::/126' 4)
[[ "$result" == '2001:db8::' ]] || { printf 'reserved /126 addresses were emitted: %s\n' "$result" >&2; exit 1; }

export IP_TEST_HOST=2001:db8::8 IP_TEST_GATEWAY=2001:db8::9 IP_TEST_ROUTE=2001:db8::8
result=$(generate_ipv6_candidates '2001:db8::8/127' 2)
[[ -z "$result" ]] || { printf 'exhausted /127 emitted %s\n' "$result" >&2; exit 1; }

export IP_TEST_HOST=2001:db8::1 IP_TEST_GATEWAY=2001:db8::2 IP_TEST_ROUTE=2001:db8::4
result=$(generate_ipv6_candidates '2001:db8::/120' 5)
[[ "${result%%$'\n'*}" == '2001:db8::3' ]] || { printf 'unexpected /120 candidates: %s\n' "$result" >&2; exit 1; }
[[ "$result" != *'2001:db8::4'* ]] || { printf 'reserved /120 route was emitted: %s\n' "$result" >&2; exit 1; }
export IP_TEST_MULTIPATH=1 IP_TEST_ROUTE=2001:db8::5
result=$(generate_ipv6_candidates '2001:db8::/120' 8)
[[ "$result" != *'2001:db8::3'* && "$result" != *'2001:db8::4'* && "$result" != *'2001:db8::5'* ]] || {
    printf 'nested default-route gateway or route was emitted: %s\n' "$result" >&2
    exit 1
}
unset IP_TEST_MULTIPATH
IP_TEST_SCENARIO=malformed generate_ipv6_candidates '2001:db8::/120' 5 >/dev/null 2>&1 && {
    echo 'localized non-JSON output was accepted' >&2
    exit 1
}

echo 'Incus IPv6 reserved-address tests passed'
