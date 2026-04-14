#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2026.04.14
# Restore IPv6 addresses and NAT rules on reboot
# Supports iptables (primary) and nftables (fallback)

# Detect network interface - lshw is primary (original method)
get_interface() {
    if command -v lshw >/dev/null 2>&1; then
        lshw -C network 2>/dev/null | awk '/logical name:/{print $3}' | head -1
    else
        comm -23 \
            <(ls /sys/class/net/ 2>/dev/null | sort) \
            <(ls /sys/devices/virtual/net/ 2>/dev/null | sort) \
            | head -1
    fi
}

interface=$(get_interface)
if [ -z "$interface" ]; then
    echo "Error: Cannot detect network interface"
    exit 1
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
            if ! ip -6 addr show dev "$interface" | grep -qw "$parameter"; then
                ip addr add "$parameter"/64 dev "$interface" 2>/dev/null || true
            fi
        done
        # Restore ip6tables rules
        if command -v ip6tables-restore >/dev/null 2>&1; then
            ip6tables-restore <"$file" 2>/dev/null || true
        elif command -v ip6tables-legacy-restore >/dev/null 2>&1; then
            ip6tables-legacy-restore <"$file" 2>/dev/null || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
            netfilter-persistent reload 2>/dev/null || true
        fi
        exit 0
    fi
fi

# Fallback: restore from nftables config (new method)
if command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ]; then
    echo "Restoring nftables rules..."
    # Extract IPv6 addresses from nftables config for ip addr add
    nft_ipv6_addrs=$(grep -oE 'ip6 daddr [0-9a-fA-F:]+' /etc/nftables.conf 2>/dev/null | awk '{print $3}')
    for addr in $nft_ipv6_addrs; do
        if ! ip -6 addr show dev "$interface" | grep -qw "$addr"; then
            ip addr add "${addr}/64" dev "$interface" 2>/dev/null || true
        fi
    done
    nft -f /etc/nftables.conf 2>/dev/null || true
    exit 0
fi

echo "No IPv6 rules found to restore"
exit 0
