#!/usr/bin/env bash
# Exercise the production removal function without touching host packages.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_code=$(awk '/^uninstall_incus_debian_packages\(\) \{/ { active=1 } active { print } active && /^}$/ { exit }' "$repo_root/scripts/uninstall_incus.sh")
[ -n "$source_code" ] || { echo 'Missing package cleanup function' >&2; exit 1; }
eval "$source_code"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mock_package_listing=$'incus\tinstalled\nincus-base\tinstalled\nincus-client\tinstalled\nincus-agent\tinstalled\nincus-extra\tnot-installed\nimportant-application\tinstalled'
query_status=0
remove_status=0
calls=()
dpkg-query() {
    [ "$*" = '-W -f=${binary:Package}\t${db:Status-Status}\n' ] || return 97
    printf '%s\n' "$mock_package_listing"
    return "$query_status"
}
apt-get() { calls+=("$*"); return "$remove_status"; }
apt_with_lock_timeout() { calls+=("lock:$*"); return "$remove_status"; }
uninstall_incus_debian_packages || fail 'Debian package selection failed'
[ "${calls[*]}" = 'lock:remove --purge -y incus incus-base incus-client incus-agent' ] || fail 'missing optional or unrelated package included'

mock_package_listing=$'incus:amd64\tinstalled\nincus-ui-canonical\tconfig-files\nincus-extra\tunpacked\nincus-base\thalf-configured'
calls=()
uninstall_incus_debian_packages || fail 'partial install / config leftovers failed'
[ "${calls[*]}" = 'lock:remove --purge -y incus:amd64 incus-ui-canonical incus-extra incus-base' ] || fail 'recoverable package states omitted'

mock_package_listing=$'incus\tnot-installed\nother-incus-helper\tinstalled'
calls=()
uninstall_incus_debian_packages || fail 'empty installation should be idempotent'
[ "${#calls[@]}" -eq 0 ] || fail 'apt was called without owned packages'

mock_package_listing=$'incus\tinstalled'
query_status=2
calls=()
if uninstall_incus_debian_packages; then fail 'inventory failure was ignored'; fi
[ "${#calls[@]}" -eq 0 ] || fail 'inventory failure triggered removal'

query_status=0
remove_status=100
calls=()
status=0
uninstall_incus_debian_packages || status=$?
[ "$status" -eq 100 ] || fail 'apt removal failure was swallowed'
printf 'PASS: Incus Debian removal selection, partial states, idempotence and failures (5 scenarios)\n'

source_code=$(awk '/^remove_incus_nftables_config\(\) \{/ { active=1 } active { print } active && /^}$/ { exit }' "$repo_root/scripts/uninstall_incus.sh")
eval "$source_code"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
printf '%s\n' \
    '# preserve host configuration' \
    'include "/etc/nftables.d/*.nft"' \
    'include "/etc/nftables.d/oneclickvirt-incus.nft"' \
    'include "/etc/nftables.d/other.nft"' \
    'table inet host_policy { chain input { type filter hook input priority 0; } }' \
    'table inet incus_masq {' \
    '  chain postrouting {' \
    '    type nat hook postrouting priority srcnat;' \
    '  }' \
    '}' >"$test_dir/nftables.conf"
remove_incus_nftables_config "$test_dir/nftables.conf"
if grep -Eq 'oneclickvirt-incus|incus_masq' "$test_dir/nftables.conf"; then fail 'persistent runtime rules remain'; fi
grep -Fxq 'include "/etc/nftables.d/*.nft"' "$test_dir/nftables.conf" || fail 'shared wildcard include removed'
grep -Fq 'table inet host_policy' "$test_dir/nftables.conf" || fail 'unrelated host table removed'
grep -Fxq 'include "/etc/nftables.d/other.nft"' "$test_dir/nftables.conf" || fail 'unrelated include removed'
cp "$test_dir/nftables.conf" "$test_dir/expected"
remove_incus_nftables_config "$test_dir/nftables.conf"
cmp "$test_dir/expected" "$test_dir/nftables.conf" || fail 'second cleanup changed host configuration'
remove_incus_nftables_config "$test_dir/not-present"
printf 'PASS: persistent firewall cleanup preserves unrelated rules and is idempotent\n'

source_code=$(awk '/^stop_uninstalled_lxcfs\(\) \{/ { active=1 } active { print } active && /^}$/ { exit }' "$repo_root/scripts/uninstall_incus.sh")
eval "$source_code"
mock_lxcfs_installed=false mock_lxcfs_active=true mock_lxcfs_mounted=true mock_stop_status=0
calls=()
command() {
    if [ "$*" = '-v lxcfs' ]; then "$mock_lxcfs_installed"; else builtin command "$@"; fi
}
systemctl() {
    if [ "$1" = is-active ]; then "$mock_lxcfs_active"; return; fi
    [ "$*" = 'stop lxcfs.service' ] || return 98
    calls+=("$*")
    [ "$mock_stop_status" -eq 0 ] || return "$mock_stop_status"
    mock_lxcfs_active=false mock_lxcfs_mounted=false
}
findmnt() { "$mock_lxcfs_mounted"; }
_red() { :; }
mock_lxcfs_installed=true
stop_uninstalled_lxcfs || fail 'shared installed lxcfs must be preserved'
[ "${#calls[@]}" -eq 0 ] || fail 'installed lxcfs was stopped'
mock_lxcfs_installed=false
stop_uninstalled_lxcfs || fail 'orphan lxcfs was not stopped'
[ "${calls[*]}" = 'stop lxcfs.service' ] || fail 'orphan service stop not attempted'
mock_lxcfs_mounted=true
if stop_uninstalled_lxcfs; then fail 'remaining mount was ignored'; fi
mock_lxcfs_active=true mock_stop_status=1
if stop_uninstalled_lxcfs; then fail 'service stop failure was ignored'; fi
unset -f command systemctl findmnt
printf 'PASS: orphan lxcfs cleanup preserves shared installation and reports cleanup failures\n'
