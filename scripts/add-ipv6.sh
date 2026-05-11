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

# 从宿主机接口检测实际的 IPv6 前缀长度，避免硬编码 /64
# Detect the actual IPv6 prefix length from the host interface to avoid hardcoding /64
get_host_ipv6_prefixlen() {
    local iface="$1"
    local plen
    # 优先读取缓存的真实前缀（由 build_ipv6_network.sh 写入）
    if [ -f /usr/local/bin/incus_ipv6_real_prefixlen ]; then
        plen=$(tr -d '[:space:]' < /usr/local/bin/incus_ipv6_real_prefixlen 2>/dev/null)
        if [[ "$plen" =~ ^[0-9]+$ ]] && [ "$plen" -ge 1 ] && [ "$plen" -le 128 ]; then
            echo "$plen"
            return
        fi
    fi
    # 回退：从接口读取第一个全局 IPv6 地址的前缀
    plen=$(ip -6 addr show dev "$iface" 2>/dev/null | awk '/inet6.*scope global/ {print $2}' | head -1 | cut -d'/' -f2)
    if [[ "$plen" =~ ^[0-9]+$ ]] && [ "$plen" -ge 1 ] && [ "$plen" -le 128 ]; then
        echo "$plen"
    else
        echo "64"
    fi
}
host_prefixlen=$(get_host_ipv6_prefixlen "$interface")

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
                ip addr add "$parameter"/"$host_prefixlen" dev "$interface" 2>/dev/null || true
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
            ip addr add "${addr}/${host_prefixlen}" dev "$interface" 2>/dev/null || true
        fi
    done
    nft -f /etc/nftables.conf 2>/dev/null || true
    exit 0
fi

echo "No IPv6 rules found to restore"
exit 0
