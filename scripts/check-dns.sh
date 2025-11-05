#!/bin/bash
#from https://github.com/oneclickvirt/incus
# 2025.09.18
set -e

# 服务管理兼容性函数：支持systemd、OpenRC和传统service命令
# 在混合环境中会尝试多个命令以确保操作成功
service_manager() {
    local action=$1
    local service_name=$2
    local executed=false
    local success=false
    
    case "$action" in
        enable)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl enable "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-update >/dev/null 2>&1; then
                if rc-update add "$service_name" default 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v chkconfig >/dev/null 2>&1; then
                if chkconfig "$service_name" on 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            ;;
        start)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl start "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                if rc-service "$service_name" start 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                if service "$service_name" start 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            ;;
        restart)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl restart "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                if rc-service "$service_name" restart 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                if service "$service_name" restart 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            ;;
        is-active)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                    return 0
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                if rc-service "$service_name" status >/dev/null 2>&1; then
                    return 0
                fi
            fi
            if command -v service >/dev/null 2>&1; then
                if service "$service_name" status >/dev/null 2>&1; then
                    return 0
                fi
            fi
            return 1
            ;;
    esac
    
    if $executed; then
        return 0
    else
        return 1
    fi
}

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
RESOLVED_CONF="/etc/systemd/resolved.conf"

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
        local target=$(readlink /etc/resolv.conf)
        echo "/etc/resolv.conf 是软链接，指向 $target"
        # 检查是否指向 systemd-resolved 的 stub
        if [[ "$target" == *"systemd/resolve"* ]]; then
            echo "检测到 systemd-resolved stub 配置"
            return 0
        else
            echo "软链接指向非 systemd-resolved 目标"
            return 1
        fi
    else
        echo "/etc/resolv.conf 不是软链接"
        return 1
    fi
}

configure_systemd_resolved() {
    local need_ipv4=$1
    local need_ipv6=$2
    
    echo "配置 systemd-resolved..."
    
    # 备份配置文件
    backup_file "$RESOLVED_CONF"
    
    # 构建DNS服务器列表
    local dns_list=()
    local fallback_dns_list=()
    
    if $need_ipv4; then
        dns_list+=("${DNS_SERVERS_IPV4[@]}")
        fallback_dns_list+=("9.9.9.9")  # Quad9 IPv4 作为备用
    fi
    
    if $need_ipv6; then
        dns_list+=("${DNS_SERVERS_IPV6[@]}")
        fallback_dns_list+=("2620:fe::fe")  # Quad9 IPv6 作为备用
    fi
    
    # 检查是否已经配置了我们的DNS设置
    local current_dns=""
    if grep -q "^DNS=" "$RESOLVED_CONF"; then
        current_dns=$(grep "^DNS=" "$RESOLVED_CONF" | cut -d'=' -f2)
    fi
    
    local new_dns=$(join " " "${dns_list[@]}")
    local new_fallback_dns=$(join " " "${fallback_dns_list[@]}")
    
    # 如果当前配置与新配置相同，跳过
    if [ "$current_dns" = "$new_dns" ]; then
        echo "systemd-resolved DNS 配置已是最新，无需修改"
        return 0
    fi
    
    # 创建临时文件进行配置更新
    local temp_file=$(mktemp)
    local updated=false
    
    # 读取原配置文件并更新
    while IFS= read -r line; do
        if [[ "$line" =~ ^#?DNS= ]]; then
            if ! $updated; then
                echo "DNS=$new_dns" >> "$temp_file"
                updated=true
            fi
        elif [[ "$line" =~ ^#?FallbackDNS= ]]; then
            echo "FallbackDNS=$new_fallback_dns" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$RESOLVED_CONF"
    
    # 如果没有找到 DNS= 行，添加到 [Resolve] 段落下
    if ! $updated; then
        # 重新处理文件，在 [Resolve] 段落后添加配置
        > "$temp_file"  # 清空临时文件
        local in_resolve_section=false
        local dns_added=false
        
        while IFS= read -r line; do
            echo "$line" >> "$temp_file"
            if [[ "$line" == "[Resolve]" ]]; then
                in_resolve_section=true
            elif $in_resolve_section && [[ "$line" =~ ^\[.*\] ]] && [ "$line" != "[Resolve]" ]; then
                # 进入了新的段落，在这之前添加DNS配置
                if ! $dns_added; then
                    echo "DNS=$new_dns" >> "$temp_file"
                    echo "FallbackDNS=$new_fallback_dns" >> "$temp_file"
                    dns_added=true
                fi
                in_resolve_section=false
            fi
        done < "$RESOLVED_CONF"
        
        # 如果文件末尾还在 [Resolve] 段落中，添加DNS配置
        if $in_resolve_section && ! $dns_added; then
            echo "DNS=$new_dns" >> "$temp_file"
            echo "FallbackDNS=$new_fallback_dns" >> "$temp_file"
        fi
    fi
    
    # 应用新配置
    mv "$temp_file" "$RESOLVED_CONF"
    
    echo "systemd-resolved 配置已更新"
    echo "新的 DNS 服务器: $new_dns"
    echo "备用 DNS 服务器: $new_fallback_dns"
    
    # 重启 systemd-resolved 服务
    echo "重启 systemd-resolved 服务..."
    service_manager restart systemd-resolved
    
    # 等待服务启动
    sleep 2
    
    echo "systemd-resolved DNS 配置完成"
    return 0
}

write_resolv_conf() {
    if check_resolv_conf_symlink; then
        echo "检测到 /etc/resolv.conf 是 systemd-resolved 软链接"
        # 如果链接到 systemd-resolved，使用 systemd-resolved 配置
        if service_manager is-active systemd-resolved; then
            echo "systemd-resolved 服务运行中，将通过配置文件设置DNS"
            local need_ipv4=false
            local need_ipv6=false
            
            if ! $IPV4_OK; then
                need_ipv4=true
            fi
            if ! $IPV6_OK; then
                need_ipv6=true
            fi
            
            configure_systemd_resolved $need_ipv4 $need_ipv6
            return 0
        else
            echo "systemd-resolved 服务未运行，启动服务..."
            service_manager start systemd-resolved
            service_manager enable systemd-resolved
            # 递归调用自身来配置
            configure_systemd_resolved true true
            return 0
        fi
    fi
    
    echo "写入 /etc/resolv.conf ..."
    backup_resolv_conf
    {
        echo "# 由 $0 生成，覆盖写入 $(date)"
        for dns in "${DNS_SERVERS_IPV4[@]}"; do
            echo "nameserver $dns"
        done
        for dns in "${DNS_SERVERS_IPV6[@]}"; do
            echo "nameserver $dns"
        done
    } > /etc/resolv.conf
    echo "/etc/resolv.conf 更新完成"
}

# 主逻辑开始
echo "开始检测DNS配置..."

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

echo "检测到DNS解析问题，开始修复..."
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
elif check_resolvectl && service_manager is-active systemd-resolved; then
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
    echo "未检测到 NetworkManager 或活跃的 systemd-resolved"
    if ! $IPV4_OK || ! $IPV6_OK; then
        echo "准备配置 DNS 解析"
        write_resolv_conf
    else
        echo "DNS 解析正常，无需修改配置"
    fi
fi

echo "DNS 配置脚本执行完成"
