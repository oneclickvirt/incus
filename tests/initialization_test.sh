#!/usr/bin/env bash
# Isolated fault injection: load definitions only; never run the installer.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/incus_install.sh"
installer_source=$(<"$installer")
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer" | sed 's#/snap/bin/lxc#lxc#g')
}
for name in api_metadata valid_storage_pool_name active_storage_pool storage_pool_exists ensure_runtime_network; do load_function "$name"; done
_green() { :; }
_yellow() { :; }
_red() { printf '%s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# RPM-family hosts previously reached install_dependencies with an empty
# package-update command.  Keep the regression assertion close to the mocked
# initialization checks so this platform-specific path cannot silently drift.
grep -Fq 'PACKAGETYPE_UPDATE="dnf -y makecache"' <<<"$installer_source" ||
    fail 'Incus RPM setup must define a successful dnf package-cache update'
grep -Fq 'PACKAGETYPE_UPDATE="yum -y makecache"' <<<"$installer_source" ||
    fail 'Incus CentOS 7 setup must define a successful yum package-cache update'
grep -Fq 'install_lsb_release()' <<<"$installer_source" ||
    fail 'Incus installer must map lsb_release executable to distro package names'
grep -Fq 'lsb-release' <<<"$installer_source" ||
    fail 'Incus installer must use the Debian lsb-release package name'
grep -Fq 'install_gpg()' <<<"$installer_source" ||
    fail 'Incus installer must map gpg executable to distro package names'
grep -Fq 'systemctl daemon-reload 2>/dev/null; then' <<<"$installer_source" ||
    fail 'Incus service-manager must propagate daemon-reload failures'
if grep -Fq 'install_package lsb_release' <<<"$installer_source"; then
    fail 'Incus installer must not install the lsb_release executable name as a package'
fi
if grep -Fq 'PACKAGETYPE_UPDATE="dnf check-update"' <<<"$installer_source" ||
   grep -Fq 'PACKAGETYPE_UPDATE="yum check-update"' <<<"$installer_source"; then
    fail 'Incus installer must not treat check-update exit 100 as a fatal install error'
fi
STORAGE_POOL_FILE=/nonexistent/oneclickvirt-test-pool
mock_pool_list=local
mock_profile='{"devices":{}}'
mock_profiles=default
mock_bridge_exists=false
mock_bridge_external=false
mock_network_config='{"managed":true,"type":"bridge","config":{"ipv4.address":"10.77.0.1/24","ipv4.dhcp":"true","ipv4.nat":"true","ipv6.address":"none"}}'
mock_network_create_fails=false
mock_ipv6_fails=false
mock_daemon_fails=false
mock_changes=0
mock_api_envelope=true
emit_api() {
    if $mock_api_envelope; then
        jq -cn --argjson metadata "$1" '{type:"sync",status:"Success",status_code:200,metadata:$metadata}'
    else
        printf '%s\n' "$1"
    fi
}
incus() {
    case "$*" in
        info) ! $mock_daemon_fails ;;
        'query /1.0/profiles/default') emit_api "$mock_profile" ;;
        'storage list --format csv -c n') printf '%s\n' "$mock_pool_list" ;;
        'storage show '*) grep -Fxq "$3" <<< "$mock_pool_list" ;;
        'profile list --format csv -c n') printf '%s\n' "$mock_profiles" ;;
        'profile create default') mock_profiles=default; mock_changes=$((mock_changes + 1)) ;;
        'profile device add default root disk path=/ pool=local')
            mock_profile=$(jq '.devices.root = {"type":"disk","path":"/","pool":"local"}' <<< "$mock_profile")
            mock_changes=$((mock_changes + 1)) ;;
        'profile device add default eth0 nic network=incusbr0 name=eth0')
            mock_profile=$(jq '.devices.eth0 = {"type":"nic","network":"incusbr0","name":"eth0"}' <<< "$mock_profile")
            mock_changes=$((mock_changes + 1)) ;;
        'network list --format csv -c n') if $mock_bridge_exists; then printf '%s\n' incusbr0; fi ;;
        'network create incusbr0 ipv4.address=auto ipv4.nat=true ipv4.dhcp=true ipv6.address=none')
            $mock_network_create_fails && return 1
            mock_bridge_exists=true; mock_changes=$((mock_changes + 1)) ;;
        'network set incusbr0 ipv6.address auto') ! $mock_ipv6_fails ;;
        'query /1.0/networks/incusbr0') emit_api "$mock_network_config" ;;
        'network show custom') return 0 ;;
        *) printf 'Unexpected incus: %s\n' "$*" >&2; return 1 ;;
    esac
}
ip() {
    [[ "$*" == 'link show dev incusbr0' ]] || return 1
    $mock_bridge_exists || $mock_bridge_external
}
(
    mock_profiles=""
    ensure_runtime_network || fail 'existing local pool + missing profile/bridge must be repaired'
    [[ "$mock_changes" == 4 ]] || fail 'must create only profile, root, bridge and NIC'
    jq -e '.devices.root.pool == "local" and .devices.eth0.network == "incusbr0"' <<< "$mock_profile" >/dev/null
    before=$mock_changes
    ensure_runtime_network || fail 'second run must succeed'
    [[ "$mock_changes" == "$before" ]] || fail 'second run must leave configured devices and network intact'
)
(
    mock_profile='{"devices":{"root":{"type":"disk","path":"/","pool":"local"},"eth0":{"type":"nic","network":"incusbr0"}}}'
    mock_ipv6_fails=true
    ensure_runtime_network || fail 'missing referenced bridge must be repaired even without IPv6'
    [[ "$mock_changes" == 1 ]] || fail 'only the missing bridge should be created'
)
(
    mock_profile='{"devices":{"root":{"type":"disk","path":"/","pool":"local"},"eth0":{"type":"nic","network":"custom"}}}'
    ensure_runtime_network || fail 'custom default-profile network must be preserved'
    [[ "$mock_changes" == 1 ]] || fail 'installer bridge should be created without changing custom network'
    jq -e '.devices.eth0.network == "custom"' <<< "$mock_profile" >/dev/null || fail 'custom network changed'
)
(
    mock_bridge_external=true
    if ensure_runtime_network; then fail 'must reject an unmanaged host bridge collision'; fi
)
(
    mock_network_create_fails=true
    if ensure_runtime_network; then fail 'network creation failure must propagate'; fi
    jq -e '.devices.eth0 == null' <<< "$mock_profile" >/dev/null || fail 'must not attach a failed network'
)
(
    mock_daemon_fails=true
    if ensure_runtime_network; then fail 'unavailable daemon must fail'; fi
    [[ "$mock_changes" == 0 ]] || fail 'must stop before modifying configuration'
)
(
    mock_pool_list=$'local\nother'
    if active_storage_pool; then fail 'multiple unselected pools must not be guessed'; fi
)
(
    mock_bridge_exists=true
    mock_network_config=$(jq '.config["ipv4.address"] = "none"' <<< "$mock_network_config")
    if ensure_runtime_network; then fail 'disabled required IPv4 must be reported'; fi
    [[ "$(jq -r '.config["ipv4.address"]' <<< "$mock_network_config")" == none ]] || fail 'explicit setting changed'
)
(
    load_function setup_storage
    active_storage_pool() { printf '%s\n' local; }
    record_storage_pool() { return 1; }
    if setup_storage; then fail 'failure to record the selected pool must propagate'; fi
)
(
    # Compatibility with wrappers that return the metadata object directly.
    mock_api_envelope=false
    mock_profile='{"devices":{"root":{"type":"disk","path":"/","pool":"local"},"eth0":{"type":"nic","network":"incusbr0"}}}'
    mock_bridge_exists=true
    ensure_runtime_network || fail 'direct metadata responses must remain supported'
)
# The panel entry point is a second installer path. Keep it fail-closed and
# avoid re-enabling IPv6/DNS settings that an administrator explicitly chose.
panel_init="$repo_root/panel_scripts/panel_init.sh"
grep -Fq 'ensure_runtime_storage || exit 1' "$panel_init" || fail 'panel init must repair an empty storage configuration before profile/network setup'
grep -Fq 'incus admin init --auto' "$panel_init" || fail 'panel init must initialize an uninitialized Incus daemon'
grep -Fq 'verify_runtime_network || exit 1' "$panel_init" || fail 'panel init must verify runtime readiness'
grep -Fq 'if ! prepare_package_manager; then' "$panel_init" || fail 'panel init must propagate package-manager failures'
grep -Fq 'incus network set incusbr0 ipv4.address auto || return 1' "$panel_init" || fail 'panel init must repair an unset IPv4 address'
grep -Fq 'incus network set incusbr0 ipv4.nat true || return 1' "$panel_init" || fail 'panel init must repair an unset IPv4 NAT setting'
configure_line=$(grep -n '^configure_default_network_settings || exit 1$' "$panel_init" | head -1 | cut -d: -f1)
storage_line=$(grep -n '^ensure_runtime_storage || exit 1$' "$panel_init" | head -1 | cut -d: -f1)
verify_line=$(grep -n '^verify_runtime_network || exit 1$' "$panel_init" | head -1 | cut -d: -f1)
[[ -n "$storage_line" && -n "$configure_line" && -n "$verify_line" && "$storage_line" -lt "$configure_line" && "$configure_line" -lt "$verify_line" ]] || fail 'panel init must initialize storage and repair defaults before strict verification'
if grep -Eq '^incus network set incusbr0 ipv6.address auto$' "$panel_init"; then
    fail 'panel init must preserve explicit IPv6 settings'
fi
grep -Fq 'incus network set incusbr0 ipv4.dhcp true || return 1' "$panel_init" ||
    fail 'panel init must require IPv4 DHCP when it is unset'
grep -Fq 'install_uidmap()' "$panel_init" ||
    fail 'Incus panel init must map uidmap package names per distribution'
printf 'Incus initialization fault-injection tests passed (10 scenarios)\n'
