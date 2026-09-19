#!/usr/bin/env bash
# Exercise installer persistence with real files and injected command failures.
# Every /etc write is redirected to a disposable local fixture.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [ -f "$repo_root/scripts/incus_install.sh" ]; then
    runtime=incus
    installer="$repo_root/scripts/incus_install.sh"
    entry=save_firewall_rules
else
    runtime=lxd
    installer="$repo_root/scripts/lxdinstall.sh"
    entry=setup_network_preferences
fi
load_function() {
    local definition
    definition=$(awk -v name="$1" '$0==name "() {" { active=1 } active {print} active && /^}$/ {exit}' "$installer")
    [ -n "$definition" ] || return 1
    eval "${definition//\/etc\//$test_dir/etc/}"
}
load_function "$entry"
load_function save_iptables_persistence || fail 'missing atomic persistence helper'
load_function iptables_persistence_file || fail 'missing persistence path selection'
load_function ensure_iptables_persistent || fail 'missing persistence service setup'
load_function nftables_persistence_file || fail 'missing nft persistence path selection'
load_function enable_nftables_persistence || fail 'missing nft persistence service setup'
mkdir -p "$test_dir/etc/iptables"
policy="$test_dir/etc/iptables/rules.v4"
printf '%s\n' '*filter' ':INPUT DROP [0:0]' COMMIT >"$policy"
printf '%s\n' 'IPv6 policy must remain unchanged' >"$test_dir/etc/iptables/rules.v6"
cp "$policy" "$test_dir/original"
cp "$test_dir/etc/iptables/rules.v6" "$test_dir/original-v6"
chmod 640 "$policy"
failure=save
iptables-save() {
    printf '%s\n' '*nat' ':POSTROUTING ACCEPT [0:0]'
    if [ "$failure" = save ]; then return 41; fi
    printf '%s\n' COMMIT
}
ip6tables-save() { fail 'IPv4 setup must not overwrite unchanged IPv6 persistence'; }
netfilter-persistent() { fail 'do not overwrite files again with global save'; }
ensure_bridge_netfilter() { :; }
install_package() { :; }
add_iptables_masq_once() { :; }
service_manager() { :; }
SYSTEM=Debian
nft_available=false
command() {
    if [ "$*" = '-v nft' ]; then "$nft_available"; return $?; fi
    if [ "$*" = '-v firewall-cmd' ]; then return 1; fi
    builtin command "$@"
}
if "$entry"; then fail "$runtime accepted a failed snapshot"; fi
cmp "$policy" "$test_dir/original" || fail "$runtime truncated the saved IPv4 policy on command failure"
cmp "$test_dir/etc/iptables/rules.v6" "$test_dir/original-v6" || fail "$runtime overwrote the unrelated IPv6 policy"
failure=none
(
    cp() { return 43; }
    if "$entry"; then fail "$runtime accepted a failed metadata copy"; fi
)
cmp "$policy" "$test_dir/original" || fail "$runtime changed policy on metadata failure"
(
    mv() { return 42; }
    if "$entry"; then fail "$runtime accepted a failed atomic replacement"; fi
)
cmp "$policy" "$test_dir/original" || fail "$runtime changed policy before atomic replacement"
if compgen -G "$test_dir/etc/iptables/.oneclickvirt-iptables.*" >/dev/null; then
    fail "$runtime retained failed temporary snapshots"
fi
"$entry" || fail "$runtime failed to save valid rules"
printf '%s\n' '*nat' ':POSTROUTING ACCEPT [0:0]' COMMIT >"$test_dir/expected"
cmp "$policy" "$test_dir/expected" || fail "$runtime saved an incomplete snapshot"
[ "$(stat -c %a "$policy" 2>/dev/null || stat -f %Lp "$policy")" = 640 ] || fail "$runtime changed existing policy permissions"
mv "$policy" "$test_dir/policy-target"
ln -s "$test_dir/policy-target" "$policy"
"$entry" || fail "$runtime failed to save through a policy symlink"
[ -L "$policy" ] || fail "$runtime replaced the policy symlink"
cmp "$test_dir/policy-target" "$test_dir/expected" || fail "$runtime failed to update symlink target"
rm -- "$policy"
"$entry" || fail "$runtime could not create missing policy"
[ "$(stat -c %a "$policy" 2>/dev/null || stat -f %Lp "$policy")" = 600 ] || fail "$runtime new policy should be private"
rm -- "$policy"
ln -s "$test_dir/missing-policy-target" "$policy"
if "$entry"; then fail "$runtime accepted a dangling policy symlink"; fi
[ -L "$policy" ] && [ ! -e "$test_dir/missing-policy-target" ] || fail "$runtime changed a dangling symlink"
rm -- "$policy"
mkdir "$policy"
if "$entry"; then fail "$runtime accepted a directory as a policy"; fi
[ -d "$policy" ] || fail "$runtime replaced an unexpected policy directory"
if [ "$runtime" = incus ]; then
    load_function ensure_nftables
    PACKAGETYPE_INSTALL=install_mock
    install_mock() { nft_available=true; }
    systemctl() {
        printf '%s\n' "$*" >>"$test_dir/systemctl-calls"
    }
    ensure_nftables || fail 'nftables installation failed'
    [ ! -e "$test_dir/systemctl-calls" ] || fail 'package installation armed persistence before saving configuration'
fi
printf 'PASS: %s atomic IPv4 persistence, failure propagation, metadata, symlinks and IPv6 preservation\n' "$runtime"
for spec in 'Debian iptables-persistent netfilter-persistent /iptables/rules.v4' \
    'Ubuntu iptables-persistent netfilter-persistent /iptables/rules.v4' \
    'CentOS iptables-services iptables /sysconfig/iptables' \
    'Fedora iptables-services iptables /sysconfig/iptables' \
    'Arch none iptables /iptables/iptables.rules' \
    'Alpine iptables-openrc iptables /iptables/rules-save'; do
    read -r SYSTEM expected_package expected_service expected_file <<<"$spec"
    [ "$(iptables_persistence_file)" = "$test_dir/etc$expected_file" ] || fail "$SYSTEM persistence file mismatch"
    install_package() { printf 'package %s\n' "$*" >>"$test_dir/service-calls"; }
    service_manager() { printf 'service %s\n' "$*" >>"$test_dir/service-calls"; }
    : >"$test_dir/service-calls"
    ensure_iptables_persistent || fail "$SYSTEM persistence initialization"
    grep -Fxq "service enable $expected_service" "$test_dir/service-calls" || fail "$SYSTEM boot service not enabled"
    if [ "$expected_package" != none ]; then
        grep -Fxq "package $expected_package" "$test_dir/service-calls" || fail "$SYSTEM persistence package missing"
    fi
done
SYSTEM=Debian
(
    install_package() { return 44; }
    if ensure_iptables_persistent; then fail 'package failure reported as success'; fi
)
(
    service_manager() { return 45; }
    if ensure_iptables_persistent; then fail 'service enable failure reported as success'; fi
)
SYSTEM=Unknown
if iptables_persistence_file >/dev/null 2>&1; then fail 'unsupported persistence reported as supported'; fi
if ensure_iptables_persistent; then fail 'unsupported service reported as supported'; fi
printf 'PASS: %s distro persistence paths, packages, boot enablement and failure propagation\n' "$runtime"
(
    # Run the real persistence caller: a good on-disk snapshot does not prove
    # the boot service accepted enablement. Never start/reload the live policy.
    nft_available=true
    SYSTEM=Debian
    mkdir -p "$test_dir/etc/nftables.d"
    printf '%s\n' '# administrator configuration' >"$test_dir/etc/nftables.conf"
    mock_enable_status=0
    mock_main_config="$test_dir/etc/nftables.conf"
    service_manager() {
        [ "$*" = 'enable nftables' ] || fail "unexpected service mutation: $*"
        [ -s "$test_dir/etc/nftables.d/oneclickvirt-$runtime.nft" ] || fail 'enabled before snapshot existed'
        grep -Fq "oneclickvirt-$runtime.nft" "$mock_main_config" || fail 'enabled before include existed'
        return "$mock_enable_status"
    }
    nft() {
        case "$*" in
            'list tables') printf 'table inet %s_masq\n' "$runtime" ;;
            'list table inet incus_masq') printf '%s\n' 'table inet incus_masq {}' ;;
            'list table inet lxd_nat') printf '%s\n' 'table inet lxd_nat {}' ;;
            *) fail "unexpected nft operation: $*" ;;
        esac
    }
    configure_nft_masquerade() { :; }
    if [ "$runtime" = lxd ]; then load_function save_lxd_nat_rules; fi
    "$entry" || fail 'nft persistence enablement failed'
    cp "$test_dir/etc/nftables.conf" "$test_dir/nft-main-before"
    cp "$test_dir/etc/nftables.d/oneclickvirt-$runtime.nft" "$test_dir/nft-snapshot-before"
    mock_enable_status=46
    if "$entry"; then fail 'nft boot service failure reported as installation success'; fi
    cmp "$test_dir/nft-main-before" "$test_dir/etc/nftables.conf" || fail 'failed enablement changed administrator configuration'
    cmp "$test_dir/nft-snapshot-before" "$test_dir/etc/nftables.d/oneclickvirt-$runtime.nft" || fail 'failed enablement lost saved rules'
    mock_enable_status=0
    for SYSTEM in Debian Ubuntu CentOS Fedora Arch Alpine; do
        mock_main_config=$(nftables_persistence_file)
        mkdir -p -- "$(dirname -- "$mock_main_config")"
        printf '%s\n' '# administrator configuration' >"$mock_main_config"
        "$entry" || fail "$SYSTEM real persistence caller failed"
        grep -Fxq '# administrator configuration' "$mock_main_config" || fail "$SYSTEM host policy lost"
        cp "$mock_main_config" "$test_dir/nft-config-before"
        "$entry" || fail "$SYSTEM repeated persistence caller failed"
        cmp "$test_dir/nft-config-before" "$mock_main_config" || fail "$SYSTEM include not idempotent"
    done
)
printf 'PASS: %s nft boot enablement ordering and failure propagation\n' "$runtime"
for spec in 'Debian /nftables.conf' 'Ubuntu /nftables.conf' 'Arch /nftables.conf' \
    'CentOS /sysconfig/nftables.conf' 'Fedora /sysconfig/nftables.conf' 'Alpine /nftables.nft'; do
    read -r SYSTEM expected_file <<<"$spec"
    [ "$(nftables_persistence_file)" = "$test_dir/etc$expected_file" ] || fail "$SYSTEM nft persistence file mismatch"
    : >"$test_dir/nft-service-calls"
    install_package() { printf 'package %s\n' "$*" >>"$test_dir/nft-service-calls"; }
    service_manager() { printf 'service %s\n' "$*" >>"$test_dir/nft-service-calls"; }
    enable_nftables_persistence || fail "$SYSTEM nft boot enablement"
    grep -Fxq 'service enable nftables' "$test_dir/nft-service-calls" || fail "$SYSTEM nft service not enabled"
    if [ "$SYSTEM" = Alpine ]; then
        grep -Fxq 'package nftables-openrc' "$test_dir/nft-service-calls" || fail 'missing Alpine service package'
    fi
done
(
    SYSTEM=Alpine
    install_package() { return 47; }
    service_manager() { fail 'service enabled after package failure'; }
    if enable_nftables_persistence; then fail 'Alpine service package failure ignored'; fi
)
SYSTEM=Unknown
if nftables_persistence_file >/dev/null 2>&1; then fail 'unsupported nft persistence accepted'; fi
printf 'PASS: %s nft distro paths and OpenRC package failure propagation\n' "$runtime"
