#!/bin/bash
#from https://github.com/oneclickvirt/incus
# 2025.08.03
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

GAI_CONF="/etc/gai.conf"

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

check_ipv4_connectivity() {
    echo "检查IPv4连通性..."
    if timeout 5 dig @8.8.8.8 ipv4.ip.sb A +short >/dev/null 2>&1; then
        echo "IPv4 DNS解析正常"
        return 0
    else
        echo "IPv4 DNS解析异常"
        return 1
    fi
}

check_ipv6_connectivity() {
    echo "检查IPv6连通性..."
    if timeout 5 dig @2001:4860:4860::8888 ipv6.ip.sb AAAA +short >/dev/null 2>&1; then
        echo "IPv6 DNS解析正常"
        return 0
    else
        echo "IPv6 DNS解析异常"
        return 1
    fi
}

backup_file() {
    local file=$1
    local backup_suffix=".bak.original"
    local backup_file="${file}${backup_suffix}"
    if [ ! -f "$backup_file" ]; then
        echo "备份 $file 到 $backup_file"
        cp "$file" "$backup_file"
    else
        echo "备份文件 $backup_file 已存在，跳过备份"
    fi
}

set_ipv4_precedence_gai() {
    echo "配置 IPv4 优先，修改 $GAI_CONF"
    if [ ! -f "$GAI_CONF" ]; then
        touch "$GAI_CONF"
    fi
    if grep -q "^precedence ::ffff:0:0/96  100" "$GAI_CONF"; then
        echo "$GAI_CONF 中 IPv4 优先规则已存在。"
    else
        backup_file "$GAI_CONF"
        echo -e "\n# 增加 IPv4 优先规则，2025.05.18 自动添加" >>"$GAI_CONF"
        echo "precedence ::ffff:0:0/96  100" >>"$GAI_CONF"
        echo "IPv4 优先规则已添加到 $GAI_CONF"
    fi
}

adjust_nmcli_ipv6_route_metric() {
    local CONN_NAME=$1
    echo "调整连接 $CONN_NAME 的 IPv6 路由 metric 以降低 IPv6 优先级"
    local METRIC=$(nmcli connection show "$CONN_NAME" | grep '^ipv6.route-metric:' | awk '{print $2}')
    if [ -z "$METRIC" ]; then
        METRIC=100
    fi
    local NEW_METRIC=$((METRIC + 100))
    nmcli connection modify "$CONN_NAME" ipv6.route-metric "$NEW_METRIC"
    echo "IPv6 路由 metric 从 $METRIC 调整到 $NEW_METRIC"
}

backup_resolv_conf() {
    local backup_file="/etc/resolv.conf.bak.original"
    if [ ! -f "$backup_file" ]; then
        echo "备份 /etc/resolv.conf 到 $backup_file"
        cp /etc/resolv.conf "$backup_file"
    else
        echo "备份文件 $backup_file 已存在，跳过备份"
    fi
}

check_resolv_conf_symlink() {
    if [ -L "/etc/resolv.conf" ]; then
        echo "/etc/resolv.conf 是软链接，指向 $(readlink /etc/resolv.conf)"
        return 0
    else
        echo "/etc/resolv.conf 不是软链接"
        return 1
    fi
}

write_resolv_conf() {
    if check_resolv_conf_symlink; then
        echo "检测到 /etc/resolv.conf 是软链接，跳过直接修改"
        return 0
    fi
    echo "写入 /etc/resolv.conf ..."
    backup_resolv_conf
    {
        echo "# 由 /usr/local/bin/check-dns.sh 生成，覆盖写入"
        for dns in "${DNS_SERVERS_IPV4[@]}"; do
            echo "nameserver $dns"
        done
        for dns in "${DNS_SERVERS_IPV6[@]}"; do
            echo "nameserver $dns"
        done
    } > /etc/resolv.conf
    echo "/etc/resolv.conf 更新完成"
}

IPV4_OK=false
IPV6_OK=false
if check_ipv4_connectivity; then
    IPV4_OK=true
fi

if check_ipv6_connectivity; then
    IPV6_OK=true
fi
if $IPV4_OK && $IPV6_OK; then
    echo "IPv4和IPv6 DNS解析都正常，无需修改配置"
    exit 0
fi
set_ipv4_precedence_gai
if check_nmcli; then
    echo "检测到 NetworkManager，使用 nmcli 设置 DNS 和路由优先"
    CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1)
    if [ -z "$CONN_NAME" ]; then
        echo "未检测到活动连接，退出。"
        exit 1
    fi
    echo "活动连接: $CONN_NAME"
    NEED_UPDATE=false
    if ! $IPV4_OK; then
        echo "IPv4 DNS需要修改"
        nmcli connection modify "$CONN_NAME" ipv4.ignore-auto-dns yes
        nmcli connection modify "$CONN_NAME" ipv4.dns "$(join ' ' "${DNS_SERVERS_IPV4[@]}")"
        NEED_UPDATE=true
    else
        echo "IPv4 DNS解析正常，保持不变"
    fi
    if ! $IPV6_OK; then
        echo "IPv6 DNS需要修改"
        nmcli connection modify "$CONN_NAME" ipv6.ignore-auto-dns yes
        nmcli connection modify "$CONN_NAME" ipv6.dns "$(join ' ' "${DNS_SERVERS_IPV6[@]}")"
        echo "调整 IPv6 路由 metric"
        adjust_nmcli_ipv6_route_metric "$CONN_NAME"
        NEED_UPDATE=true
    else
        echo "IPv6 DNS解析正常，保持不变"
    fi
    if $NEED_UPDATE; then
        echo "重启连接应用配置..."
        nmcli connection down "$CONN_NAME"
        nmcli connection up "$CONN_NAME"
        echo "DNS 配置已更新。"
    else
        echo "DNS 配置无需更新。"
    fi
elif check_resolvectl && systemctl is-active --quiet systemd-resolved; then
    echo "检测到 systemd-resolved，使用 resolvectl 设置 DNS"
    IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$IFACE" ]; then
        echo "未检测到默认网络接口，退出。"
        exit 1
    fi
    echo "默认接口: $IFACE"
    NEED_UPDATE=false
    DNS_TO_SET=()
    if ! $IPV4_OK; then
        echo "IPv4 DNS需要修改"
        DNS_TO_SET+=("${DNS_SERVERS_IPV4[@]}")
        NEED_UPDATE=true
    fi
    if ! $IPV6_OK; then
        echo "IPv6 DNS需要修改"
        DNS_TO_SET+=("${DNS_SERVERS_IPV6[@]}")
        NEED_UPDATE=true
    fi
    if $NEED_UPDATE; then
        echo "设置 DNS 服务器: ${DNS_TO_SET[*]}"
        resolvectl dns "$IFACE" "${DNS_TO_SET[@]}"
        echo "DNS 配置已更新。"
    else
        echo "DNS 配置无需更新。"
    fi
else
    echo "未检测到 NetworkManager 或 systemd-resolved"
    if check_resolv_conf_symlink; then
        echo "由于 /etc/resolv.conf 是软链接，建议检查链接目标的DNS配置"
        exit 0
    fi
    if ! $IPV4_OK || ! $IPV6_OK; then
        echo "准备直接修改 /etc/resolv.conf"
        write_resolv_conf
    else
        echo "DNS 解析正常，无需修改 /etc/resolv.conf"
    fi
fi
