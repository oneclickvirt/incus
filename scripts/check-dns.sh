#!/bin/bash
#from https://github.com/oneclickvirt/incus
# 2025.05.18

set -e

DNS_SERVERS_IPV4=(
    "1.1.1.1"
    "8.8.8.8"
    "8.8.4.4"
)

DNS_SERVERS_IPV6=(
    "2606:4700:4700::1111"
    "2001:4860:4860::8888"
    "2001:4860:4860::8844"
)

join() {
    local IFS="$1"
    shift
    echo "$*"
}

check_nmcli() {
    command -v nmcli >/dev/null 2>&1
}

check_resolvectl() {
    command -v resolvectl >/dev/null 2>&1
}

backup_resolv_conf() {
    local backup_file="/etc/resolv.conf.bak.$(date +%F-%T)"
    echo "备份 /etc/resolv.conf 到 $backup_file"
    cp /etc/resolv.conf "$backup_file"
}

write_resolv_conf() {
    echo "写入 /etc/resolv.conf ..."
    {
        echo "# 由 /usr/local/bin/check-dns.sh 生成，覆盖写入"
        echo "search spiritlhl.net"
        for dns in "${DNS_SERVERS_IPV4[@]}"; do
            echo "nameserver $dns"
        done
        for dns in "${DNS_SERVERS_IPV6[@]}"; do
            echo "nameserver $dns"
        done
    } >/etc/resolv.conf
    echo "/etc/resolv.conf 更新完成"
}

if check_nmcli; then
    echo "检测到 NetworkManager，使用 nmcli 设置 DNS"
    CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1)
    if [ -z "$CONN_NAME" ]; then
        echo "未检测到活动连接，退出。"
        exit 1
    fi
    echo "活动连接: $CONN_NAME"
    TARGET_IPV6="2001:4860:4860::8844"
    CURRENT_IPV6_DNS=$(nmcli connection show "$CONN_NAME" | grep '^ipv6.dns:' | awk '{print $2}')
    if echo "$CURRENT_IPV6_DNS" | grep -qw "$TARGET_IPV6"; then
        echo "IPv6 DNS $TARGET_IPV6 已存在于连接 $CONN_NAME"
    else
        echo "设置 IPv4 DNS: ${DNS_SERVERS_IPV4[*]}"
        echo "设置 IPv6 DNS: ${DNS_SERVERS_IPV6[*]}"
        nmcli connection modify "$CONN_NAME" ipv4.ignore-auto-dns yes
        nmcli connection modify "$CONN_NAME" ipv6.ignore-auto-dns yes
        nmcli connection modify "$CONN_NAME" ipv4.dns "$(join ' ' "${DNS_SERVERS_IPV4[@]}")"
        nmcli connection modify "$CONN_NAME" ipv6.dns "$(join ' ' "${DNS_SERVERS_IPV6[@]}")"
        echo "重启连接应用配置..."
        nmcli connection down "$CONN_NAME"
        nmcli connection up "$CONN_NAME"
        echo "DNS 配置已更新。"
    fi

elif check_resolvectl && systemctl is-active --quiet systemd-resolved; then
    echo "检测到 systemd-resolved，使用 resolvectl 设置 DNS"
    IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$IFACE" ]; then
        echo "未检测到默认网络接口，退出。"
        exit 1
    fi
    echo "默认接口: $IFACE"
    TARGET_IPV6="2001:4860:4860::8844"
    CURRENT_DNS=$(resolvectl dns "$IFACE")
    if echo "$CURRENT_DNS" | grep -qw "$TARGET_IPV6"; then
        echo "IPv6 DNS $TARGET_IPV6 已存在于接口 $IFACE"
    else
        echo "设置 DNS 服务器..."
        resolvectl dns "$IFACE" "${DNS_SERVERS_IPV4[@]}" "${DNS_SERVERS_IPV6[@]}"
        resolvectl domain "$IFACE" "spiritlhl.net"
        echo "DNS 配置已更新。"
    fi

else
    echo "未检测到 NetworkManager 或 systemd-resolved，准备直接修改 /etc/resolv.conf"
    backup_resolv_conf
    write_resolv_conf
fi
