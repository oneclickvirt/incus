#!/usr/bin/env bash
# Execute panel initialization definitions only. No installer, host service,
# package manager or real network command is run.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
panel_init="$repo_root/panel_scripts/panel_init.sh"
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$panel_init")
}
for name in ensure_runtime_storage select_storage_pool_for_profile ensure_default_bridge ensure_default_profile_devices configure_default_network_settings verify_runtime_network; do
    load_function "$name"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
_red() { printf '%s\n' "$*" >&2; }
_yellow() { :; }
mock_dir=$(mktemp -d)
trap 'rm -f -- "$mock_dir/calls" "$mock_dir/initialized"; rmdir -- "$mock_dir"' EXIT
mock_pools=local mock_profiles=default mock_bridge_exists=true
mock_list_fails=false mock_query_fails=false mock_network_query_fails=false
mock_empty_profile=false mock_init_fails=false mock_create_pool=false
mock_bridge_fails=false mock_ipv6_fails=false mock_envelope=false
mock_profile='{"devices":{"root":{"type":"disk","path":"/","pool":"local"},"eth0":{"type":"nic","network":"incusbr0","name":"eth0"}}}'
mock_network='{"type":"bridge","managed":true,"config":{"ipv4.address":"10.77.0.1/24","ipv4.nat":"true","ipv4.dhcp":"true","ipv6.address":"none","dns.mode":"managed"}}'
emit_api() {
    if $mock_envelope; then jq -cn --argjson metadata "$1" '{type:"sync",metadata:$metadata}'; else printf '%s\n' "$1"; fi
}
incus() {
    printf '%s\n' "$*" >>"$mock_dir/calls"
    case "$*" in
        info|'admin waitready --timeout=120') return 0 ;;
        'admin init --auto')
            $mock_init_fails && return 1
            $mock_create_pool || : >"$mock_dir/initialized"
            return 0 ;;
        'storage list --format csv -c n')
            if [[ -f "$mock_dir/initialized" ]]; then printf '%s\n' local; else printf '%s\n' "$mock_pools"; fi ;;
        'storage create default dir') mock_pools=default ;;
        'storage show '*) grep -Fxq "$3" <<<"$mock_pools" ;;
        'profile list --format csv -c n')
            $mock_list_fails && return 1
            printf '%s\n' "$mock_profiles" ;;
        'profile create default')
            [[ -z "$mock_profiles" ]] || fail 'existing profile must not be recreated'
            mock_profiles=default mock_profile='{"devices":{}}' ;;
        'query /1.0/profiles/default')
            $mock_query_fails && return 1
            if ! $mock_empty_profile; then emit_api "$mock_profile"; fi ;;
        'profile device add default root disk path=/ pool='*)
            mock_profile=$(jq --arg pool "${8#pool=}" '.devices.root={type:"disk",path:"/",pool:$pool}' <<<"$mock_profile") ;;
        'profile device add default eth0 nic network=incusbr0 name=eth0')
            mock_profile=$(jq '.devices.eth0={type:"nic",network:"incusbr0",name:"eth0"}' <<<"$mock_profile") ;;
        'network list --format csv -c n') if $mock_bridge_exists; then printf '%s\n' incusbr0; fi ;;
        'network create incusbr0 ipv4.address=auto ipv4.nat=true ipv4.dhcp=true ipv6.address=none')
            $mock_bridge_fails && return 1
            mock_bridge_exists=true ;;
        'network set incusbr0 ipv6.address auto') ! $mock_ipv6_fails ;;
        'network set incusbr0 '*)
            mock_network=$(jq --arg key "$4" --arg value "$5" '.config[$key]=$value' <<<"$mock_network") ;;
        'query /1.0/networks/incusbr0')
            $mock_network_query_fails && return 1
            emit_api "$mock_network" ;;
        'network show custom') return 0 ;;
        *) fail "Unexpected runtime command: $*" ;;
    esac
}

ip() { [[ "$*" == 'link show dev incusbr0' ]] && $mock_bridge_exists; }
sleep() { :; }
mutation_count() { awk '/^(profile (create|device)|network (create|set)|storage create)/ {count++} END {print count+0}' "$mock_dir/calls"; }

(
    # Match the installer's lack of pipefail; the test runner must not mask
    # the pipeline error that originally prevented profile creation.
    set +o pipefail
    mock_profiles="" mock_bridge_exists=false mock_ipv6_fails=true
    : >"$mock_dir/calls"
    ensure_runtime_storage && configure_default_network_settings && ensure_default_profile_devices && verify_runtime_network ||
        fail 'half-initialized daemon must recover without IPv6'
    jq -e '.devices.root.pool == "local" and .devices.eth0.network == "incusbr0"' <<<"$mock_profile" >/dev/null ||
        fail 'repaired profile must have a usable root and NIC'
    count=$(mutation_count)
    ensure_runtime_storage && configure_default_network_settings && ensure_default_profile_devices && verify_runtime_network ||
        fail 'second run must succeed'
    [[ "$(mutation_count)" == "$count" ]] || fail 'repeat initialization changed existing configuration'
)
(
    mock_pools=$'local\nother'
    : >"$mock_dir/calls"
    ensure_runtime_storage && ensure_default_profile_devices || fail 'existing profile must select local among multiple pools'
    [[ "$(mutation_count)" == 0 ]] || fail 'existing pool/profile must be preserved'
)
(
    mock_pools=$'local\nother' mock_profile='{"devices":{}}'
    : >"$mock_dir/calls"
    if ensure_default_profile_devices; then fail 'ambiguous unselected pools must not be guessed'; fi
    [[ "$(mutation_count)" == 0 ]] || fail 'ambiguous pool selection changed the profile'
)
for failure in list query empty malformed; do
    (
        set +o pipefail
        : >"$mock_dir/calls"
        case "$failure" in
            list) mock_list_fails=true ;;
            query) mock_query_fails=true ;;
            empty) mock_empty_profile=true ;;
            malformed) mock_profile='{"type":"error","error":"unavailable"}' ;;
        esac
        if ensure_default_profile_devices; then fail "$failure profile response must fail"; fi
        [[ "$(mutation_count)" == 0 ]] || fail "$failure response triggered profile modifications"
    )
done
for envelope in false true; do
    (
        mock_envelope=$envelope
        mock_profile=$(jq '.devices.eth0.network="custom"' <<<"$mock_profile")
        mock_network=$(jq 'del(.config["dns.mode"]) | .config["raw.dnsmasq"]="dhcp-option=6,10.0.0.53\nserver=/internal/10.0.0.54"' <<<"$mock_network")
        : >"$mock_dir/calls"
        configure_default_network_settings && ensure_default_profile_devices && verify_runtime_network ||
            fail 'custom configuration must support direct and wrapped API responses'
        jq -e '.config["raw.dnsmasq"]=="dhcp-option=6,10.0.0.53\nserver=/internal/10.0.0.54" and .config["ipv6.address"]=="none"' <<<"$mock_network" >/dev/null ||
            fail 'custom DNS/IPv6 setting was overwritten'
        [[ "$(mutation_count)" == 1 ]] || fail 'only unset dns.mode should be configured'
    )
done
for failure in query empty unmanaged disabled_dhcp; do
    (
        set +o pipefail
        : >"$mock_dir/calls"
        case "$failure" in
            query) mock_network_query_fails=true ;;
            empty) emit_api() { :; } ;;
            unmanaged) mock_network=$(jq '.managed=false' <<<"$mock_network") ;;
            disabled_dhcp) mock_network=$(jq '.config["ipv4.dhcp"]="false"' <<<"$mock_network") ;;
        esac
        if configure_default_network_settings; then fail "$failure network response must fail"; fi
        [[ "$(mutation_count)" == 0 ]] || fail "$failure network response caused configuration changes"
    )
done
(
    mock_bridge_exists=false mock_bridge_fails=true
    if configure_default_network_settings; then fail 'bridge creation failure must propagate'; fi
)
(
    mock_pools="" mock_init_fails=true
    if ensure_runtime_storage; then fail 'empty runtime initialization failure must propagate'; fi
)
(
    mock_pools=""
    ensure_runtime_storage || fail 'fresh runtime must be initialized'
    [[ -f "$mock_dir/initialized" ]] || fail 'auto initialization was not called'
)
rm -f -- "$mock_dir/initialized"
(
    mock_pools="" mock_create_pool=true
    ensure_runtime_storage || fail 'initialized runtime with no pool must receive a dir pool'
    [[ "$mock_pools" == default ]] || fail 'dir fallback did not create the default pool'
)
(
    mock_network=$(jq '.config["ipv4.nat"]="false"' <<<"$mock_network")
    : >"$mock_dir/calls"
    configure_default_network_settings && verify_runtime_network || fail 'external routing/NAT configuration must remain supported'
    [[ "$(mutation_count)" == 0 ]] || fail 'explicitly disabled daemon NAT must remain unchanged'
)
printf 'Incus panel initialization passed (19 scenarios, no skipped tests)\n'
