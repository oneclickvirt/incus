#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2026.08.26
# Restore IPv6 addresses and NAT rules on reboot
# Supports iptables (primary) and nftables (fallback)

STATE_DIR="${INCUS_STATE_DIR:-/usr/local/bin}"

valid_interface_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

read_strict_prefix_len() {
    local file="$1" value lines
    [ -f "$file" ] || return 1
    lines=$(awk 'END { print NR + 0 }' "$file" 2>/dev/null) || return 1
    [ "$lines" -eq 1 ] || return 1
    IFS= read -r value <"$file" || [ -n "$value" ] || return 1
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 128 ] || return 1
    printf '%s\n' "$value"
}

get_saved_interface() {
    local saved
    saved=$(cat "$STATE_DIR/incus_ipv6_mapping_interface" 2>/dev/null || true)
    valid_interface_name "$saved" || return 1
    ip link show dev "$saved" >/dev/null 2>&1 || return 1
    printf '%s\n' "$saved"
}

# iproute2 JSON field names do not change with the host's display language.
# Some wrappers still add terminal color even when JSON was requested.
restore_ipv6_json_rows() {
    local mode="$1" target="${2:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$mode" "$target" <<'PY'
import ipaddress
import json
import os
import re
import subprocess
import sys

mode, target = sys.argv[1:]
if mode == "default":
    args = ["-6", "route", "show", "default"]
elif mode == "addresses":
    args = ["-6", "addr", "show"]
    if target:
        args += ["dev", target]
else:
    raise SystemExit(1)
try:
    env = dict(os.environ, LC_ALL="C", NO_COLOR="1")
    raw = subprocess.check_output(["ip", "-j", *args], env=env,
                                  stderr=subprocess.DEVNULL)
    data = json.loads(re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw))
    if not isinstance(data, list):
        raise ValueError("invalid ip JSON")
    if mode == "default":
        for route in data:
            if route.get("dst", "default") == "default" and route.get("dev"):
                print(route["dev"])
    else:
        for interface in data:
            name = interface.get("ifname", "")
            for item in interface.get("addr_info", []):
                if item.get("family") != "inet6" or item.get("scope") != "global" or item.get("tentative") or "tentative" in item.get("flags", []):
                    continue
                address = ipaddress.IPv6Address(item["local"])
                prefix = int(item["prefixlen"])
                ipaddress.IPv6Interface(f"{address}/{prefix}")
                if address in ipaddress.IPv6Network("2000::/3") and address.is_global:
                    print(name, address.compressed, prefix, sep="\t")
except (OSError, subprocess.CalledProcessError, ValueError, KeyError, TypeError):
    raise SystemExit(1)
PY
}

# Prefer the interface recorded by the mapping creator, then the IPv6 default
# route. This is required for tunnel and routed-bridge hosts; lshw alone often
# returns the underlying physical NIC instead.
get_interface() {
    local iface iface_path candidate
    if iface=$(get_saved_interface); then
        printf '%s\n' "$iface"
        return 0
    fi
    iface=$(restore_ipv6_json_rows default 2>/dev/null | head -1)
    if valid_interface_name "$iface" && ip link show dev "$iface" >/dev/null 2>&1; then
        printf '%s\n' "$iface"
        return 0
    fi
    iface=$(restore_ipv6_json_rows addresses 2>/dev/null | awk -F '\t' 'NF == 3 {print $1; exit}')
    if valid_interface_name "$iface" && ip link show dev "$iface" >/dev/null 2>&1; then
        printf '%s\n' "$iface"
        return 0
    fi
    for iface_path in /sys/class/net/*; do
        [ -e "$iface_path" ] || continue
        candidate=$(basename "$iface_path")
        [ -e "/sys/devices/virtual/net/$candidate" ] && continue
        if valid_interface_name "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

get_host_ipv6_prefixlen() {
    local iface="$1" plen
    plen=$(read_strict_prefix_len "$STATE_DIR/incus_ipv6_mapping_prefix_len" 2>/dev/null || true)
    if [ -n "$plen" ]; then
        printf '%s\n' "$plen"
        return 0
    fi
    plen=$(restore_ipv6_json_rows addresses "$iface" 2>/dev/null | awk -F '\t' 'NF == 3 {print $3; exit}')
    [[ "$plen" =~ ^[0-9]+$ ]] && [ "$plen" -ge 1 ] && [ "$plen" -le 128 ] || return 1
    printf '%s\n' "$plen"
}

is_restorable_global_ipv6() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${1:-}" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address in ipaddress.IPv6Network("2000::/3") and address.is_global else 1)
PY
}

normalize_restorable_global_ipv6() {
    python3 - "${1:-}" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if address not in ipaddress.IPv6Network("2000::/3") or not address.is_global:
    raise SystemExit(1)
print(address.compressed)
PY
}

restore_address() {
    local address="$1" interface="$2" prefix_len="$3" rows
    [[ "$prefix_len" =~ ^[0-9]+$ ]] && [ "$prefix_len" -ge 1 ] && [ "$prefix_len" -le 128 ] || return 1
    address=$(normalize_restorable_global_ipv6 "$address" 2>/dev/null) || return 0
    rows=$(restore_ipv6_json_rows addresses "$interface") || return 1
    if ! printf '%s\n' "$rows" | awk -F '\t' -v addr="$address" '$2 == addr {found=1} END {exit !found}'; then
        # A mapped address is a host alias, not another connected prefix.
        ip -6 addr replace "$address/128" dev "$interface" 2>/dev/null || return 1
    fi
}

main() {
    local interface host_prefixlen file parameter nft_ipv6_addrs addr
    interface=$(get_interface)
    if [ -z "$interface" ]; then
        echo "Error: Cannot detect network interface"
        return 1
    fi

    host_prefixlen=$(get_host_ipv6_prefixlen "$interface" 2>/dev/null || true)
    if [ -z "$host_prefixlen" ]; then
        echo "No valid persisted or live IPv6 prefix length; leaving addresses unchanged"
        return 0
    fi

    if [ "$(cat "$STATE_DIR/incus_ipv6_mode" 2>/dev/null || true)" = "nat66" ]; then
        echo "NAT66 mode is active; no public IPv6 address restoration is required"
        return 0
    fi

# Primary: restore from iptables rules.v6 (original method)
file="/etc/iptables/rules.v6"
if [ -f "$file" ]; then
    array=()
    while IFS= read -r line; do
        if [[ $line == "-A PREROUTING -d"* ]]; then
            parameter="${line#*-d }"
            parameter="${parameter%%/*}"
            array+=("$parameter")
        fi
    done <"$file"

    if [ ${#array[@]} -gt 0 ]; then
        for parameter in "${array[@]}"; do
            restore_address "$parameter" "$interface" "$host_prefixlen" || return 1
        done
        # Restore ip6tables rules
        if command -v ip6tables-restore >/dev/null 2>&1; then
            ip6tables-restore <"$file" 2>/dev/null || return 1
        elif command -v ip6tables-legacy-restore >/dev/null 2>&1; then
            ip6tables-legacy-restore <"$file" 2>/dev/null || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || return 1
            netfilter-persistent reload 2>/dev/null || return 1
        fi
        return 0
    fi
fi

# Fallback: restore from nftables config (new method)
if command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ]; then
    echo "Restoring nftables rules..."
    # Extract IPv6 addresses from nftables config for ip addr add
    nft_ipv6_addrs=$(grep -oE 'ip6 daddr [0-9A-Fa-f:]+([/][0-9]{1,3})?' /etc/nftables.conf 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
    for addr in $nft_ipv6_addrs; do
        restore_address "$addr" "$interface" "$host_prefixlen" || return 1
    done
    nft -f /etc/nftables.conf 2>/dev/null || return 1
    return 0
fi

echo "No IPv6 rules found to restore"
return 0
}

if [ "${ONECLICKVIRT_TESTING:-0}" != "1" ]; then
    main "$@"
fi
