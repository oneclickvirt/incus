#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/state"
cat >"$test_dir/bin/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    '-j -6 route show default')
        printf '\033[35m%s\033[0m\n' '[{"dst":"default","dev":"eth0","description":"Route par défaut / Standardroute / 默认路由"}]'
        ;;
    '-j -6 addr show'|'-j -6 addr show dev eth0'|'-j -6 addr show dev vmbr2')
        if [[ "${TEST_BAD_JSON:-0}" == 1 ]]; then
            printf '%s\n' 'inet6 2606:4700::1/64 Bereich global'
            exit 0
        fi
        local_part='{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2606:4700::1","prefixlen":128,"scope":"global"},{"family":"inet6","local":"fd42::1","prefixlen":64,"scope":"global"}]}'
        bridge_part="{\"ifname\":\"vmbr2\",\"addr_info\":[{\"family\":\"inet6\",\"local\":\"2606:4700::2\",\"prefixlen\":${TEST_PREFIX:-64},\"scope\":\"global\"}]}"
        if [[ "$*" == *'dev eth0' ]]; then
            printf '\033[36m[%s]\033[0m\n' "$local_part"
        elif [[ "$*" == *'dev vmbr2' ]]; then
            printf '\033[36m[%s]\033[0m\n' "$bridge_part"
        else
            printf '\033[36m[%s,%s]\033[0m\n' "$local_part" "$bridge_part"
        fi
        ;;
    'link show dev eth0'|'link show dev vmbr2') : ;;
    '-6 addr replace '*)
        printf '%s\n' "$*" >>"${TEST_LOG:?}"
        ;;
    *)
        printf 'unexpected textual ip call: %s\n' "$*" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$test_dir/bin/ip"
export PATH="$test_dir/bin:$PATH" INCUS_STATE_DIR="$test_dir/state" ONECLICKVIRT_TESTING=1 TEST_LOG="$test_dir/ip-writes"
source "$repo_root/scripts/add-ipv6.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $(get_interface) == eth0 ]] || fail 'localized and colored default route was not parsed'
[[ $(get_host_ipv6_prefixlen eth0) == 128 ]] || fail 'host /128 prefix was not detected'

printf '%s\n' vmbr2 >"$INCUS_STATE_DIR/incus_ipv6_mapping_interface"
[[ $(get_interface) == vmbr2 ]] || fail 'saved bridge did not take precedence over default route'
for prefix in 38 64 119 127; do
    export TEST_PREFIX="$prefix"
    [[ $(get_host_ipv6_prefixlen vmbr2) == "$prefix" ]] || fail "bridge /$prefix prefix was not detected"
done
printf '%s\n' 119 >"$INCUS_STATE_DIR/incus_ipv6_mapping_prefix_len"
[[ $(get_host_ipv6_prefixlen vmbr2) == 119 ]] || fail 'persisted prefix did not take precedence'

restore_address '2606:4700::1' eth0 128 || fail 'existing host address could not be checked'
[[ ! -e "$TEST_LOG" ]] || fail 'existing host address was replaced'
restore_address '2606:4700::3' vmbr2 119 || fail 'missing mapped address could not be restored'
[[ $(cat "$TEST_LOG") == '-6 addr replace 2606:4700::3/128 dev vmbr2' ]] || fail 'mapped address changed the host connected prefix'
export TEST_BAD_JSON=1
if restore_address '2606:4700::4' vmbr2 119; then
    fail 'malformed ip JSON was accepted for address restoration'
fi
[[ $(wc -l <"$TEST_LOG" | tr -d ' ') == 1 ]] || fail 'malformed ip JSON caused an address write'
printf 'add-ipv6 restore tests passed\n'
