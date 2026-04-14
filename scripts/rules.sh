#!/bin/bash
# from https://github.com/oneclickvirt/incus
# 2026.04.14

# Try to ensure nftables is available
ensure_nftables() {
    if command -v nft >/dev/null 2>&1; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y nftables >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nftables >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nftables >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm nftables >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add nftables >/dev/null 2>&1
    fi
    if command -v nft >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
            systemctl start nftables 2>/dev/null || true
        fi
        return 0
    fi
    return 1
}

ensure_iptables_persistent() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
    fi
}

save_firewall_rules() {
    if command -v nft >/dev/null 2>&1; then
        # Only save our own custom tables, NOT incusd's managed 'incus' table.
        # Saving 'nft list ruleset' would include incusd's transient tables which
        # reference interfaces (incusbr0) that don't exist at nftables.service
        # start time, causing firewall/SSH breakage on reboot.
        {
            nft list table inet incus_masq 2>/dev/null || true
            nft list table inet incus_block 2>/dev/null || true
        } > /etc/nftables.conf
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
        fi
    else
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        fi
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
}

# Block scanning/attack tools inside containers via apparmor
if ! dpkg -s apparmor &>/dev/null 2>&1; then
    apt-get install apparmor 2>/dev/null || true
fi
containers=$(incus list -c n --format csv 2>/dev/null)
for container_name in $containers; do
    incus profile set "$container_name" raw.apparmor "deny /usr/bin/zmap x, deny /usr/bin/nmap x, deny /usr/bin/masscan x, deny /usr/bin/medusa x," 2>/dev/null || true
done

# Block installation of scanning tools on host
divert_install_script() {
    local package_name=$1
    local divert_script="/usr/local/sbin/${package_name}-install"
    local install_script="/var/lib/dpkg/info/${package_name}.postinst"
    ln -sf "${divert_script}" "${install_script}" 2>/dev/null || true
    sh -c "echo '#!/bin/bash' > ${divert_script}"
    sh -c "echo 'exit 1' >> ${divert_script}"
    chmod +x "${divert_script}"
}

if command -v apt-get >/dev/null 2>&1; then
    echo "Package: zmap nmap masscan medusa apache2-utils hping3
Pin: release *
Pin-Priority: -1" | sudo tee -a /etc/apt/preferences >/dev/null 2>&1
    apt-get update >/dev/null 2>&1
fi
divert_install_script "zmap"
divert_install_script "nmap"
divert_install_script "masscan"
divert_install_script "medusa"
divert_install_script "hping3"
divert_install_script "apache2-utils"

# Detect primary outbound interface
iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$iface" ]; then
    iface=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | grep -v 'veth\|br\|incus\|docker\|tap' | head -1)
fi
if [ -z "$iface" ]; then
    iface="eth0"
fi

# Block traffic on specific ports and websites
blocked_ports=(3389 8888 54321 65432)
blocked_sites=("zmap.io" "nmap.org" "foofus.net")

if ensure_nftables; then
    # Use nftables for port blocking and website blocking
    nft add table inet incus_block 2>/dev/null || true
    nft add chain inet incus_block forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || true
    nft add chain inet incus_block output '{ type filter hook output priority filter; policy accept; }' 2>/dev/null || true
    for port in "${blocked_ports[@]}"; do
        nft add rule inet incus_block forward oifname "$iface" tcp dport "$port" drop 2>/dev/null || true
        nft add rule inet incus_block forward oifname "$iface" udp dport "$port" drop 2>/dev/null || true
    done
    for site in "${blocked_sites[@]}"; do
        # Resolve site IPs and block them
        site_ips=$(getent ahosts "$site" 2>/dev/null | awk '{print $1}' | sort -u)
        for ip in $site_ips; do
            if echo "$ip" | grep -q ':'; then
                nft add rule inet incus_block output ip6 daddr "$ip" drop 2>/dev/null || true
            else
                nft add rule inet incus_block output ip daddr "$ip" drop 2>/dev/null || true
            fi
        done
    done
    save_firewall_rules
else
    # Fallback to iptables with persistence
    ensure_iptables_persistent
    for port in "${blocked_ports[@]}"; do
        iptables --ipv4 -I FORWARD -o "$iface" -p tcp --dport "${port}" -j DROP 2>/dev/null || true
        iptables --ipv4 -I FORWARD -o "$iface" -p udp --dport "${port}" -j DROP 2>/dev/null || true
    done
    for site in "${blocked_sites[@]}"; do
        iptables -A OUTPUT -d "$site" -j DROP -m comment --comment "block $site" 2>/dev/null || true
    done
    save_firewall_rules
fi
