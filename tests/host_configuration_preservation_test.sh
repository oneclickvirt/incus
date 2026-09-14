#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mock_dir=$(mktemp -d)
mock_etc="$mock_dir/etc"
mkdir -p "$mock_etc/nftables.d"
trap 'rm -f -- "$mock_etc/subuid" "$mock_etc/subgid" "$mock_etc/nftables.conf" "$mock_etc/nftables.d/oneclickvirt-incus.nft"; rmdir -- "$mock_etc/nftables.d" "$mock_etc" "$mock_dir"' EXIT
load_function() {
    # Rewrite only fixed /etc paths in extracted definitions. Every write in
    # this test is confined to the newly created temporary fixture directory.
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$repo_root/scripts/incus_install.sh" | sed "s|/etc/|$mock_etc/|g")
}
load_function configure_uid_gid
load_function save_firewall_rules
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
_red() { :; }

printf '%s\n' 'other:100000:65536' 'root:200000:1048576' 'root:2000000:65536' >"$mock_etc/subuid"
printf '%s\n' 'root:300000:1048576' >"$mock_etc/subgid"
uid_before=$(cksum <"$mock_etc/subuid")
gid_before=$(cksum <"$mock_etc/subgid")
configure_uid_gid || fail 'custom ID ranges should be accepted'
[[ "$(cksum <"$mock_etc/subuid")" == "$uid_before" && "$(cksum <"$mock_etc/subgid")" == "$gid_before" ]] || fail 'existing ID maps changed'
printf '%s\n' 'other:100000:65536' >"$mock_etc/subuid"
configure_uid_gid || fail 'missing root mapping should be added'
grep -Fxq 'root:100000:65536' "$mock_etc/subuid" || fail 'root mapping not added'
grep -Fxq 'other:100000:65536' "$mock_etc/subuid" || fail 'other user mapping changed'
[[ "$(cksum <"$mock_etc/subgid")" == "$gid_before" ]] || fail 'existing group mapping changed during user-map repair'
printf '%s\n' 'root:invalid' >"$mock_etc/subuid"
if configure_uid_gid; then fail 'invalid existing mapping should be reported'; fi
[[ "$(<"$mock_etc/subuid")" == root:invalid ]] || fail 'invalid mapping must be preserved'

mock_nft_failure=false
nft() {
    $mock_nft_failure && return 1
    case "$*" in
        'list tables') printf '%s\n' 'table inet incus_masq' 'table inet incus_block' 'table inet admin' 'table inet incus' ;;
        'list table inet incus_masq') printf '%s\n' 'table inet incus_masq { chain postrouting { type nat hook postrouting priority srcnat; policy accept; masquerade; } }' ;;
        'list table inet incus_block') printf '%s\n' 'table inet incus_block { chain forward { type filter hook forward priority filter; policy accept; } }' ;;
        *) fail "must only snapshot installer tables: $*" ;;
    esac
}
systemctl() { [[ "$*" == 'enable nftables' ]] || fail 'saving rules must not restart the firewall'; }
printf '%s\n' '# existing host config' 'include "/custom/admin.nft"' >"$mock_etc/nftables.conf"
save_firewall_rules || fail 'save must preserve the main host configuration'
grep -Fxq '# existing host config' "$mock_etc/nftables.conf" || fail 'host config overwritten'
grep -Fxq 'include "/custom/admin.nft"' "$mock_etc/nftables.conf" || fail 'administrator include lost'
saved_before=$(cksum <"$mock_etc/nftables.d/oneclickvirt-incus.nft")
main_before=$(cksum <"$mock_etc/nftables.conf")
save_firewall_rules || fail 'repeat save failed'
[[ "$(cksum <"$mock_etc/nftables.conf")" == "$main_before" ]] || fail 'repeat save duplicated include'
[[ "$(cksum <"$mock_etc/nftables.d/oneclickvirt-incus.nft")" == "$saved_before" ]] || fail 'snapshot changed on repeat'
mock_nft_failure=true
if save_firewall_rules; then fail 'failed snapshot must fail'; fi
[[ "$(cksum <"$mock_etc/nftables.d/oneclickvirt-incus.nft")" == "$saved_before" ]] || fail 'failed snapshot truncated saved rules'
mock_nft_failure=false
printf 'include "%s/nftables.d/*.nft"\n' "$mock_etc" >"$mock_etc/nftables.conf"
main_before=$(cksum <"$mock_etc/nftables.conf")
save_firewall_rules || fail 'existing wildcard include must remain supported'
[[ "$(cksum <"$mock_etc/nftables.conf")" == "$main_before" ]] || fail 'wildcard include must not be duplicated'
rm -f -- "$mock_etc/nftables.conf"
save_firewall_rules || fail 'missing main nftables config must be created'
[[ -s "$mock_etc/nftables.conf" ]] || fail 'persistent rules have no main include'
printf 'Incus ID-map and firewall persistence passed (8 scenarios)\n'
