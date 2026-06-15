#!/bin/bash
# by hhttps://github.com/oneclickvirt/incus
# 2025.08.14

# 字体颜色函数
_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }

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
        daemon-reload)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload 2>/dev/null
                executed=true
                success=true
            fi
            if ! $executed; then
                success=true
            fi
            ;;
    esac
    
    if $executed; then
        return 0
    else
        return 1
    fi
}

# 检测 grep 是否支持 -E 选项
check_grep_extended_regex() {
    if echo "test" | grep -E 'test' >/dev/null 2>&1; then
        GREP_EXTENDED="-E"
    else
        GREP_EXTENDED=""
    fi
}

# 检测 grep 是否支持 -P (Perl 正则) 选项
check_grep_perl_regex() {
    if echo "test123" | grep -oP '\d+' >/dev/null 2>&1; then
        GREP_PERL_SUPPORT=true
    else
        GREP_PERL_SUPPORT=false
    fi
}

# 安全的 grep 函数
safe_grep() {
    if [ "$GREP_EXTENDED" = "-E" ]; then
        grep -E "$@"
    else
        grep "$@"
    fi
}

detect_primary_ipv6_iface() {
    local iface iface_path
    iface=$(ip -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -n "$iface" ]; then
        echo "$iface"
        return
    fi
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$iface" ]; then
        echo "$iface"
        return
    fi
    for iface_path in /sys/class/net/*; do
        [ -e "$iface_path" ] || continue
        iface=${iface_path##*/}
        case "$iface" in
        lo | veth* | br* | incus* | docker* | tap*) continue ;;
        esac
        echo "$iface"
        return
    done
    echo "eth0"
}

# 设置环境变量
setup_environment() {
    check_grep_extended_regex
    check_grep_perl_regex
    if [ ! -d "/usr/local/bin" ]; then
        mkdir -p /usr/local/bin
    fi
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
    if [[ -z "$utf8_locale" ]]; then
        _yellow "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        _green "Locale set to $utf8_locale"
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
        ubuntu | pop | neon | zorin)
            OS="ubuntu"
            if [ "${UBUNTU_CODENAME:-}" != "" ]; then
                VERSION="$UBUNTU_CODENAME"
            else
                VERSION="$VERSION_CODENAME"
            fi
            PACKAGETYPE="apt"
            PACKAGETYPE_INSTALL="apt install -y"
            PACKAGETYPE_UPDATE="apt update -y"
            PACKAGETYPE_REMOVE="apt remove -y"
            ;;
        debian)
            OS="$ID"
            VERSION="$VERSION_CODENAME"
            PACKAGETYPE="apt"
            PACKAGETYPE_INSTALL="apt install -y"
            PACKAGETYPE_UPDATE="apt update -y"
            PACKAGETYPE_REMOVE="apt remove -y"
            ;;
        kali)
            OS="debian"
            PACKAGETYPE="apt"
            PACKAGETYPE_INSTALL="apt install -y"
            PACKAGETYPE_UPDATE="apt update -y"
            PACKAGETYPE_REMOVE="apt remove -y"
            YEAR="$(echo "$VERSION_ID" | cut -f1 -d.)"
            ;;
        centos | almalinux | rocky)
            OS="$ID"
            VERSION="$VERSION_ID"
            PACKAGETYPE="dnf"
            PACKAGETYPE_INSTALL="dnf install -y"
            PACKAGETYPE_REMOVE="dnf remove -y"
            if [[ "$VERSION" =~ ^7 ]]; then
                PACKAGETYPE="yum"
            fi
            ;;
        arch | archarm | endeavouros | blendos | garuda)
            OS="arch"
            VERSION="" # rolling release
            PACKAGETYPE="pacman"
            PACKAGETYPE_INSTALL="pacman -S --noconfirm --needed"
            PACKAGETYPE_UPDATE="pacman -Sy"
            PACKAGETYPE_REMOVE="pacman -Rsc --noconfirm"
            PACKAGETYPE_ONLY_REMOVE="pacman -Rdd --noconfirm"
            ;;
        manjaro | manjaro-arm)
            OS="manjaro"
            VERSION="" # rolling release
            PACKAGETYPE="pacman"
            PACKAGETYPE_INSTALL="pacman -S --noconfirm --needed"
            PACKAGETYPE_UPDATE="pacman -Sy"
            PACKAGETYPE_REMOVE="pacman -Rsc --noconfirm"
            PACKAGETYPE_ONLY_REMOVE="pacman -Rdd --noconfirm"
            ;;
        alpine)
            OS="alpine"
            VERSION="$VERSION_ID"
            PACKAGETYPE="apk"
            PACKAGETYPE_INSTALL="apk add --no-cache"
            PACKAGETYPE_UPDATE="apk update"
            PACKAGETYPE_REMOVE="apk del"
            ;;
        esac
    fi
    if [ -z "${PACKAGETYPE:-}" ]; then
        OS="$ID"
        if command -v apt >/dev/null 2>&1; then
            PACKAGETYPE="apt"
            PACKAGETYPE_INSTALL="apt install -y"
            PACKAGETYPE_UPDATE="apt update -y"
            PACKAGETYPE_REMOVE="apt remove -y"
        elif command -v dnf >/dev/null 2>&1; then
            PACKAGETYPE="dnf"
            PACKAGETYPE_INSTALL="dnf install -y"
            PACKAGETYPE_UPDATE="dnf check-update"
            PACKAGETYPE_REMOVE="dnf remove -y"
        elif command -v yum >/dev/null 2>&1; then
            PACKAGETYPE="yum"
            PACKAGETYPE_INSTALL="yum install -y"
            PACKAGETYPE_UPDATE="yum check-update"
            PACKAGETYPE_REMOVE="yum remove -y"
        elif command -v pacman >/dev/null 2>&1; then
            PACKAGETYPE="pacman"
            PACKAGETYPE_INSTALL="pacman -S --noconfirm --needed"
            PACKAGETYPE_UPDATE="pacman -Sy"
            PACKAGETYPE_REMOVE="pacman -Rsc --noconfirm"
        elif command -v apk >/dev/null 2>&1; then
            PACKAGETYPE="apk"
            PACKAGETYPE_INSTALL="apk add --no-cache"
            PACKAGETYPE_UPDATE="apk update"
            PACKAGETYPE_REMOVE="apk del"
        fi
    fi
}

# 安装 rdisc6 工具用于从路由器获取 IPv6 配置
install_rdisc6() {
    if ! command -v rdisc6 >/dev/null 2>&1; then
        _blue "Installing ndisc6 package for IPv6 router discovery..."
        _green "正在安装 ndisc6 软件包用于 IPv6 路由器发现..."
        install_package ndisc6
    fi
}

# 从路由器通告中获取真实的 IPv6 前缀长度
get_real_ipv6_prefixlen_from_router() {
    local interface="$1"
    local current_prefixlen="$2"

    # 首先检查是否有有效的缓存值（必须是 1-128 之间的整数）
    if [ -f /usr/local/bin/incus_ipv6_real_prefixlen ]; then
        local cached_val
        cached_val=$(tr -d '[:space:]' < /usr/local/bin/incus_ipv6_real_prefixlen 2>/dev/null)
        if [[ "$cached_val" =~ ^[0-9]+$ ]] && [ "$cached_val" -ge 1 ] && [ "$cached_val" -le 128 ]; then
            echo "$cached_val"
            return 0
        else
            _yellow "Cached IPv6 prefix length '$cached_val' is invalid (must be 1-128), re-detecting..."
            _yellow "缓存的 IPv6 前缀长度 '$cached_val' 无效（需为 1-128），重新检测..."
            rm -f /usr/local/bin/incus_ipv6_real_prefixlen
        fi
    fi

    # 缓存无效或不存在，尝试从路由器通告获取
    if command -v rdisc6 >/dev/null 2>&1; then
        _blue "Attempting to get real IPv6 prefix from router advertisement..."
        _green "尝试从路由器通告中获取真实的 IPv6 前缀..."
        _blue "Using network interface: ${interface}"
        _green "正在使用网络接口: ${interface}"

        local rdisc6_output
        rdisc6_output=$(timeout 10 rdisc6 "${interface}" 2>/dev/null)

        if [ -n "$rdisc6_output" ]; then
            # 从路由器通告中提取前缀长度
            local real_prefixlen
            if [ "$GREP_PERL_SUPPORT" = true ]; then
                # 如果支持 Perl 正则，使用 grep -oP（更精确）
                real_prefixlen=$(echo "$rdisc6_output" | safe_grep "Prefix" | grep -oP '[:：]\s*[0-9a-fA-F:]+/\K\d+' | head -n 1)
            else
                # 否则使用兼容的 sed 方式，避免 Perl 正则表达式依赖
                real_prefixlen=$(echo "$rdisc6_output" | safe_grep "Prefix" | sed -n 's/.*[：:][[:space:]]*\([0-9a-fA-F:]*\)\/\([0-9]\+\).*/\2/p' | head -n 1)
            fi

            # 验证路由器通告的前缀长度必须在 1-128 之间
            if [[ "$real_prefixlen" =~ ^[0-9]+$ ]] && [ "$real_prefixlen" -ge 1 ] && [ "$real_prefixlen" -le 128 ]; then
                _green "Found real IPv6 prefix length from router advertisement: /$real_prefixlen"
                _green "从路由器通告中发现真实的 IPv6 前缀长度: /$real_prefixlen"

                if [ -z "$current_prefixlen" ]; then
                    # 当前无前缀，直接使用路由器通告值
                    echo "$real_prefixlen" >/usr/local/bin/incus_ipv6_real_prefixlen
                    echo "$real_prefixlen"
                    return 0
                fi

                # 规则1: OS 报告的前缀比路由器更宽泛（数字更小），使用路由器更精确的前缀
                #        例如 OS=/48, 路由器=/64 → 使用 /64（更符合实际分配的子网）
                if [ "$current_prefixlen" -lt "$real_prefixlen" ]; then
                    _green "Using more specific prefix /$real_prefixlen from router advertisement (OS reported /$current_prefixlen)"
                    _green "使用路由器通告的更精确前缀 /$real_prefixlen（OS 报告为 /$current_prefixlen）"
                    echo "$real_prefixlen" >/usr/local/bin/incus_ipv6_real_prefixlen
                    echo "$real_prefixlen"
                    return 0
                fi

                # 规则2: OS 报告的前缀过于精确（如 /128 主机路由），而路由器通告的是可用子网（≤64）
                #        这种情况发生在 SLAAC 或 DHCPv6 给宿主机分配了 /128，但实际子网是 /64
                if [ "$current_prefixlen" -gt 64 ] && [ "$real_prefixlen" -le 64 ]; then
                    _yellow "Current prefix /$current_prefixlen is a host route; using router-advertised subnet /$real_prefixlen"
                    _yellow "当前前缀 /$current_prefixlen 为主机路由，使用路由器通告的子网 /$real_prefixlen"
                    echo "$real_prefixlen" >/usr/local/bin/incus_ipv6_real_prefixlen
                    echo "$real_prefixlen"
                    return 0
                fi
            else
                _yellow "Could not parse valid IPv6 prefix length from router advertisement (got: '$real_prefixlen')"
                _yellow "无法从路由器通告中解析有效的 IPv6 前缀长度（获取到: '$real_prefixlen'）"
            fi
        else
            _yellow "Could not get router advertisement response on interface ${interface} (timeout or no response)"
            _yellow "无法在接口 ${interface} 获取路由器通告响应(超时或无响应)"
        fi
    fi

    # 如果无法从路由器获取，返回当前前缀长度（需确保也在有效范围内）
    if [[ "$current_prefixlen" =~ ^[0-9]+$ ]] && [ "$current_prefixlen" -ge 1 ] && [ "$current_prefixlen" -le 128 ]; then
        echo "$current_prefixlen"
    else
        _yellow "Current prefix '$current_prefixlen' also invalid, defaulting to 64"
        _yellow "当前前缀 '$current_prefixlen' 也无效，默认使用 64"
        echo "64"
    fi
    return 1
}

install_package() {
    local pkg=$1
    if command -v "$pkg" &>/dev/null; then
        _green "$pkg has been installed"
        _green "$pkg 已经安装"
        return 0
    fi
    if $PACKAGETYPE_INSTALL "$pkg"; then
        _green "$pkg has been installed"
        _green "$pkg 已尝试安装"
        return 0
    fi
    if command -v rpm >/dev/null && ! rpm -q epel-release &>/dev/null; then
        _yellow "Installing epel-release for EPEL…"
        _yellow "正在安装 epel-release 以启用 EPEL…"
        $PACKAGETYPE_INSTALL epel-release || {
            _red "Failed to install epel-release, skipping EPEL step"
            _red "安装 epel-release 失败，跳过 EPEL 步骤"
        }
    fi
    if command -v yum &>/dev/null; then
        $PACKAGETYPE_INSTALL yum-utils
        _yellow "Enabling CRB repo via yum-config-manager…"
        _yellow "通过 yum-config-manager 启用 CRB 源…"
        yum-config-manager --set-enabled crb || {
            _red "Failed to enable CRB via yum"
            _red "启用 CRB（yum）失败"
        }
    elif command -v dnf &>/dev/null; then
        _yellow "Enabling CRB repo via dnf config‑manager…"
        _yellow "通过 dnf config‑manager 启用 CRB 源…"
        dnf config-manager --set-enabled crb || {
            _red "Failed to enable CRB via dnf"
            _red "启用 CRB（dnf）失败"
        }
    fi
    _yellow "Re-trying installation of $pkg…"
    _yellow "正在重试安装 $pkg…"
    if $PACKAGETYPE_INSTALL "$pkg"; then
        _green "$pkg has been installed (with EPEL/CRB)"
        _green "$pkg 安装成功（利用 EPEL/CRB）"
        return 0
    fi
    if command -v pip3 &>/dev/null; then
        _yellow "Attempting pip3 install for $pkg…"
        _yellow "尝试通过 pip3 安装 $pkg…"
        if pip3 install --user "$pkg"; then
            _green "$pkg installed via pip3 (in ~/.local/bin)"
            _green "$pkg 已通过 pip3 安装（位于 ~/.local/bin）"
            return 0
        fi
    fi
    _red "ERROR: Unable to install $pkg – please check repos or install manually"
    _red "错误：无法安装 $pkg，请检查仓库或手动安装"
    return 1
}

# 检查CDN
check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=()
    mapfile -t shuffled_cdn_urls < <(shuf -e "${cdn_urls[@]}")
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

# 检查CDN文件
check_cdn_file() {
    if [ "${WITHOUTCDN,,}" = "true" ]; then
        export cdn_success_url=""
        echo "WITHOUTCDN=TRUE, skip CDN acceleration"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
    fi
}

# 检查是否为私有IPv6地址
is_private_ipv6() {
    local address=$1
    local temp="0"
    if [[ ! -n $address ]]; then
        temp="1"
    fi
    if [[ -n $address && $address != *":"* ]]; then
        temp="2"
    fi
    if [[ $address == fe80:* ]]; then
        temp="3"
    fi
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        temp="4"
    fi
    if [[ $address == 2001:db8* ]]; then
        temp="5"
    fi
    if [[ $address == ::1 ]]; then
        temp="6"
    fi
    if [[ $address == ::ffff:* ]]; then
        temp="7"
    fi
    if [[ $address == 2002:* ]]; then
        temp="8"
    fi
    if [[ $address == 2001:* ]]; then
        temp="9"
    fi
    if [[ $address == fd42:* ]]; then
        temp="10"
    fi
    if [ "$temp" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 检查IPv6地址
check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | head -n 1 | awk '{print $2}' | cut -d '/' -f1)
    if is_private_ipv6 "$IPV6"; then
        IPV6=""
        API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            response=$(curl -sLk6m8 "$p" | tr -d '[:space:]')
            if [ $? -eq 0 ] && ! (echo "$response" | grep -q "error"); then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    echo $IPV6 >/usr/local/bin/incus_check_ipv6
}

# 更新sysctl配置
update_sysctl() {
    sysctl_config="$1"  # 格式: key=value
    key="${sysctl_config%%=*}"
    value="${sysctl_config#*=}"
    # 目标配置文件（systemd 方式）
    custom_conf="/etc/sysctl.d/99-custom.conf"
    mkdir -p /etc/sysctl.d
    # 检查 /etc/sysctl.conf 是否存在并且在系统加载路径中
    use_etc_sysctl_conf=false
    if [ -f /etc/sysctl.conf ]; then
        if grep -q "/etc/sysctl.conf" /etc/sysctl.d/README* 2>/dev/null || \
           grep -q "/etc/sysctl.conf" /lib/systemd/system/sysctl.service 2>/dev/null; then
            use_etc_sysctl_conf=true
        fi
    fi
    # 更新 /etc/sysctl.d/99-custom.conf
    if grep -q "^$sysctl_config" "$custom_conf" 2>/dev/null; then
        : # 已经有正确配置，跳过
    elif grep -q "^#$sysctl_config" "$custom_conf" 2>/dev/null; then
        sed -i "s/^#$sysctl_config/$sysctl_config/" "$custom_conf"
    elif grep -q "^$key" "$custom_conf" 2>/dev/null; then
        sed -i "s|^$key.*|$sysctl_config|" "$custom_conf"
    else
        echo "$sysctl_config" >> "$custom_conf"
    fi
    # 如果系统还在用 /etc/sysctl.conf，也同步更新
    if [ "$use_etc_sysctl_conf" = true ]; then
        if grep -q "^$sysctl_config" /etc/sysctl.conf; then
            : # 已经有正确配置
        elif grep -q "^#$sysctl_config" /etc/sysctl.conf; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
        elif grep -q "^$key" /etc/sysctl.conf; then
            sed -i "s|^$key.*|$sysctl_config|" /etc/sysctl.conf
        else
            echo "$sysctl_config" >> /etc/sysctl.conf
        fi
    fi
    sysctl -w "$key=$value" >/dev/null 2>&1
}

# 等待容器启动
wait_for_container_running() {
    local container_name=$1
    local timeout=24
    local interval=3
    local elapsed_time=0
    while [ $elapsed_time -lt $timeout ]; do
        incus start "$container_name"
        status=$(incus info "$container_name" | grep "RUNNING")
        if [[ "$status" == *RUNNING* ]]; then
            break
        fi
        echo "Waiting for the container $container_name to run..."
        echo "${status}"
        sleep $interval
        elapsed_time=$((elapsed_time + interval))
    done
}

# 等待容器停止
wait_for_container_stopped() {
    local container_name=$1
    local timeout=24
    local interval=3
    local elapsed_time=0
    while [ $elapsed_time -lt $timeout ]; do
        incus stop "$container_name"
        status=$(incus info "$container_name" | grep "STOPPED")
        if [[ "$status" == *STOPPED* ]]; then
            break
        fi
        echo "Waiting for the container $container_name to stop..."
        echo "${status}"
        sleep $interval
        elapsed_time=$((elapsed_time + interval))
    done
}

# 获取容器内网IPv6地址
get_container_ipv6() {
    local container_name=$1
    local ipv6
    ipv6=$(incus list "$container_name" --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet6") | select(.scope=="global") | .address')
    if [ -z "$ipv6" ]; then
        _red "Container has no intranet IPV6 address, no auto-mapping"
        _red "容器无内网IPV6地址，不进行自动映射"
        exit 1
    fi
    _blue "The container with the name $container_name has an intranet IPV6 address of $ipv6"
    _blue "$container_name 容器的内网IPV6地址为 $ipv6"
    echo "$ipv6"
}

# 获取宿主机IPv6子网前缀
get_host_ipv6_prefix() {
    local prefix
    prefix=$(ip -6 addr show | safe_grep 'inet6.*global' | awk '{print $2}' | awk -F'/' '{print $1}' | head -n 1 | cut -d ':' -f1-5):
    if [ -z "$prefix" ]; then
        _red "No IPV6 subnet, no automatic mapping"
        _red "无 IPV6 子网，不进行自动映射"
        exit 1
    fi
    _blue "The IPV6 subnet prefix is $prefix"
    _blue "宿主机的IPV6子网前缀为 $prefix"
    echo "$prefix"
}

# 获取IPv6网关信息
get_ipv6_gateway_info() {
    local output
    local num_lines
    output=$(ip -6 route show | awk '/default via/{print $3}')
    num_lines=$(echo "$output" | wc -l)
    local ipv6_gateway=""
    if [ $num_lines -eq 1 ]; then
        ipv6_gateway="$output"
    elif [ $num_lines -ge 2 ]; then
        non_fe80_lines=$(echo "$output" | grep -v '^fe80')
        if [ -n "$non_fe80_lines" ]; then
            ipv6_gateway=$(echo "$non_fe80_lines" | head -n 1)
        else
            ipv6_gateway=$(echo "$output" | head -n 1)
        fi
    fi
    if [[ $ipv6_gateway == fe80* ]]; then
        echo "Y"
    else
        echo "N"
    fi
}

setup_network_device_ipv6() {
    local container_name=$1
    local container_ipv6=$2
    local ipv6_gateway_fe80=$3
    # https://pkgs.org/search/?q=sipcalc
    if [[ "$OS" == "almalinux" ]] || [[ "$OS" == "rocky" ]] || [[ "$OS" == "centos" ]]; then
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            REL_PATH="x86_64/Packages/s/sipcalc-1.1.6-17.el8.x86_64.rpm"
        elif [[ "$ARCH" == "aarch64" ]]; then
            REL_PATH="aarch64/Packages/s/sipcalc-1.1.6-17.el8.aarch64.rpm"
        else
            echo "Unsupported architecture: $ARCH"
            exit 1
        fi
        FILENAME=$(basename "$REL_PATH")
        MIRRORS=(
            "https://dl.fedoraproject.org/pub/epel/8/Everything/$REL_PATH"
            "https://mirrors.aliyun.com/epel/8/Everything/$REL_PATH"
            "https://repo.huaweicloud.com/epel/8/Everything/$REL_PATH"
            "https://mirrors.tuna.tsinghua.edu.cn/epel/8/Everything/$REL_PATH"
        )
        echo "rpm detected — installing sipcalc from EPEL ($ARCH)"
        for URL in "${MIRRORS[@]}"; do
            echo "Trying $URL"
            if curl -fLO "$URL"; then
                echo "Downloaded sipcalc from: $URL"
                break
            else
                echo "Failed to download from: $URL"
            fi
        done
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y "./$FILENAME"
        else
            yum install -y "./$FILENAME"
        fi
        rm -f "./$FILENAME"
        if ! command -v sipcalc >/dev/null 2>&1; then
            install_package epel-release
            echo "sipcalc not found after install, trying fallback package installation..."
            install_package sipcalc
        fi
    else
        install_package sipcalc
    fi
    # 安装 rdisc6 工具用于从路由器获取真实的 IPv6 前缀长度
    install_rdisc6
    if [ ! -f /usr/local/bin/incus_check_ipv6 ] || [ ! -s /usr/local/bin/incus_check_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/incus_check_ipv6)" = "" ]; then
        check_ipv6
    fi
    IPV6=$(cat /usr/local/bin/incus_check_ipv6)
    if ip -f inet6 addr | grep -q "he-ipv6"; then
        ipv6_network_name="he-ipv6"
        # 使用通用前缀模式匹配任意有效的 IPv6 前缀长度（1-128），而非仅匹配特定值
        ip_network_gam=$(ip -6 addr show ${ipv6_network_name} | grep global | awk '{print $2}' | grep -E "^${IPV6}/[0-9]+" | head -n 1 2>/dev/null)
        if [ -z "$ip_network_gam" ]; then
            # 如果精确匹配失败，回退到宿主机上该接口的第一个全局地址
            ip_network_gam=$(ip -6 addr show ${ipv6_network_name} | grep global | awk '{print $2}' | head -n 1)
        fi
    else
        ipv6_network_name=$(detect_primary_ipv6_iface)
        ip_network_gam=$(ip -6 addr show "$ipv6_network_name" | grep global | awk '{print $2}' | head -n 1)
    fi
    _yellow "Local IPV6 address: $ip_network_gam"
    # 尝试从路由器获取真实的 IPv6 前缀长度
    if [ -n "$ip_network_gam" ] && [ -n "$ipv6_network_name" ]; then
        current_prefixlen=$(echo "$ip_network_gam" | cut -d'/' -f2)
        real_prefixlen=$(get_real_ipv6_prefixlen_from_router "$ipv6_network_name" "$current_prefixlen")
        # 如果获取到真实前缀长度，并且与当前前缀长度不同，则使用真实前缀长度
        if [ -n "$real_prefixlen" ] && [ "$real_prefixlen" != "$current_prefixlen" ]; then
            ipv6_addr_only=$(echo "$ip_network_gam" | cut -d'/' -f1)
            ip_network_gam="${ipv6_addr_only}/${real_prefixlen}"
            _green "Updated IPv6 address with real prefix from router: $ip_network_gam"
            _green "使用从路由器获取的真实前缀更新 IPv6 地址: $ip_network_gam"
        fi
        # 最终安全校验：前缀长度必须在 1-128 之间
        local validated_plen
        validated_plen=$(echo "$ip_network_gam" | cut -d'/' -f2)
        if ! [[ "$validated_plen" =~ ^[0-9]+$ ]] || [ "$validated_plen" -lt 1 ] || [ "$validated_plen" -gt 128 ]; then
            _yellow "Warning: prefix length '$validated_plen' in '$ip_network_gam' is invalid, resetting to 64"
            _yellow "警告: '$ip_network_gam' 中的前缀长度 '$validated_plen' 无效，重置为 64"
            ipv6_addr_only=$(echo "$ip_network_gam" | cut -d'/' -f1)
            ip_network_gam="${ipv6_addr_only}/64"
        fi
    fi
    if [ -n "$ip_network_gam" ]; then
        update_sysctl "net.ipv6.conf.${ipv6_network_name}.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.all.forwarding=1"
        update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
        sysctl_path=$(which sysctl)
        ${sysctl_path} -p
        ipv6_lala=$(sipcalc ${ip_network_gam} | grep "Compressed address" | awk '{print $4}' | awk -F: '{NF--; print}' OFS=:):
        randbits=$(od -An -N2 -t x1 /dev/urandom | tr -d ' ')
        incus_ipv6="${ipv6_lala%/*}${randbits}"
        _green "Conatiner $container_name IPV6:"
        _green "$incus_ipv6"
        incus stop "$container_name"
        sleep 3
        wait_for_container_stopped "$container_name"
        incus config device add "$container_name" eth1 nic nictype=routed parent="$ipv6_network_name" ipv6.address="$incus_ipv6"
        sleep 3
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=trusted --add-interface="$ipv6_network_name"
            firewall-cmd --reload
        elif command -v ufw >/dev/null 2>&1; then
            ufw allow in on "$ipv6_network_name"
            ufw allow out on "$ipv6_network_name"
            ufw reload
        fi
        incus start "$container_name"
        if [[ "${ipv6_gateway_fe80}" == "N" ]]; then
            inter=$(detect_primary_ipv6_iface)
            del_ip=$(ip -6 addr show dev "$inter" | awk '/inet6 fe80/ {print $2}')
            if [ -n "$del_ip" ]; then
                ip addr del "$del_ip" dev "$inter"
                echo '#!/bin/bash' >/usr/local/bin/remove_route.sh
                echo "ip addr del ${del_ip} dev ${inter}" >>/usr/local/bin/remove_route.sh
                chmod 755 /usr/local/bin/remove_route.sh
                if ! crontab -l 2>/dev/null | grep -Fq '/usr/local/bin/remove_route.sh'; then
                    (crontab -l 2>/dev/null; echo '@reboot /usr/local/bin/remove_route.sh') | crontab -
                fi
            fi
        fi
        local cron_line
        cron_line='*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb'
        if ! crontab -l 2>/dev/null | grep -Fqx "$cron_line"; then
            (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        fi
        echo "$incus_ipv6" >>"$container_name"_v6
    fi
}

setup_iptables_ipv6() {
    local container_name=$1
    local container_ipv6=$2
    local subnet_prefix=$3
    local ipv6_length=$4
    local interface=$5
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    # Try to ensure nftables is available
    local use_nft=false
    if command -v nft >/dev/null 2>&1; then
        use_nft=true
    else
        $PACKAGETYPE_INSTALL nftables >/dev/null 2>&1 || true
        if command -v nft >/dev/null 2>&1; then
            use_nft=true
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable nftables 2>/dev/null || true
                systemctl start nftables 2>/dev/null || true
            fi
        fi
    fi
    # Find available IPv6 address
    for i in $(seq 3 65535); do
        IPV6="${subnet_prefix}$i"
        [[ $IPV6 == "$container_ipv6" ]] && continue
        ip -6 addr show dev "$interface" | grep -qw "$IPV6" && continue
        if ! ping6 -c1 -w1 -q "$IPV6" &>/dev/null; then
            if [ "$use_nft" = true ]; then
                if ! nft list ruleset 2>/dev/null | grep -q "dnat ip6 to $container_ipv6" 2>/dev/null || ! nft list ruleset 2>/dev/null | grep -q "$IPV6" 2>/dev/null; then
                    _green "$IPV6"
                    break
                fi
            else
                if ! ip6tables -t nat -C PREROUTING -d "$IPV6" -j DNAT --to-destination "$container_ipv6" &>/dev/null; then
                    _green "$IPV6"
                    break
                fi
            fi
        fi
        _yellow "$IPV6"
    done
    if [ -z "$IPV6" ]; then
        _red "No IPV6 address available, no auto mapping"
        _red "无可用 IPV6 地址，不进行自动映射"
        exit 1
    fi
    # 使用前再次校验前缀长度，确保不超过 128
    if ! [[ "$ipv6_length" =~ ^[0-9]+$ ]] || [ "$ipv6_length" -lt 1 ] || [ "$ipv6_length" -gt 128 ]; then
        _yellow "Warning: IPv6 prefix length '$ipv6_length' invalid in setup_iptables_ipv6, defaulting to 64"
        _yellow "警告: setup_iptables_ipv6 中 IPv6 前缀长度 '$ipv6_length' 无效，默认使用 64"
        ipv6_length=64
    fi
    ip addr add "$IPV6"/"$ipv6_length" dev "$interface"
    if [ "$use_nft" = true ]; then
        # Use nftables for IPv6 DNAT (handles v6 natively)
        nft add table ip6 incus_ipv6_nat 2>/dev/null || true
        nft add chain ip6 incus_ipv6_nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
        if ! nft list chain ip6 incus_ipv6_nat prerouting 2>/dev/null | grep -F -- "ip6 daddr $IPV6 dnat to $container_ipv6" >/dev/null 2>&1; then
            nft add rule ip6 incus_ipv6_nat prerouting ip6 daddr "$IPV6" dnat to "$container_ipv6"
        fi
        # Persist only our own tables, not incusd's managed 'incus' table
        {
            nft list table ip6 incus_ipv6_nat 2>/dev/null || true
            nft list table inet incus_masq 2>/dev/null || true
            nft list table inet incus_block 2>/dev/null || true
        } > /etc/nftables.conf
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        service_manager enable firewalld
        service_manager start firewalld
        sleep 3
        firewall-cmd --permanent --direct --query-rule ipv6 nat PREROUTING 0 -d "$IPV6" -j DNAT --to-destination "$container_ipv6" >/dev/null 2>&1 ||
            firewall-cmd --permanent --direct --add-rule ipv6 nat PREROUTING 0 -d "$IPV6" -j DNAT --to-destination "$container_ipv6"
        firewall-cmd --reload
    else
        # Fallback to ip6tables with persistence
        ip6tables -t nat -C PREROUTING -d "$IPV6" -j DNAT --to-destination "$container_ipv6" 2>/dev/null ||
            ip6tables -t nat -A PREROUTING -d "$IPV6" -j DNAT --to-destination "$container_ipv6"
        if command -v apt >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
        fi
        mkdir -p /etc/iptables
        ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        fi
    fi
    # Install add-ipv6 reboot restoration service
    if [ ! -f /usr/local/bin/add-ipv6.sh ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/add-ipv6.sh -O /usr/local/bin/add-ipv6.sh
        chmod +x /usr/local/bin/add-ipv6.sh
    fi
    if [ ! -f /etc/systemd/system/add-ipv6.service ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/add-ipv6.service -O /etc/systemd/system/add-ipv6.service
        chmod +x /etc/systemd/system/add-ipv6.service
        service_manager daemon-reload
        service_manager enable add-ipv6.service
        service_manager start add-ipv6.service
    fi
    if ping6 -c 3 "$IPV6" &>/dev/null; then
        _green "$container_name The external IPV6 address of the container is $IPV6"
        _green "$container_name 容器的外网IPV6地址为 $IPV6"
    else
        _red "Mapping failure"
        _red "映射失败"
        exit 1
    fi
    echo "$IPV6" >>"${container_name}_v6"
}

main() {
    CONTAINER_NAME="$1"
    use_iptables="${2:-N}"
    use_iptables=$(echo "$use_iptables" | tr '[:upper:]' '[:lower:]')
    setup_environment
    detect_os
    install_package sudo
    install_package lshw
    install_package jq
    install_package net-tools
    install_package cron
    interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
    _yellow "NIC $interface"
    _yellow "网卡 $interface"
    incus start "$CONTAINER_NAME"
    sleep 3
    wait_for_container_running "$CONTAINER_NAME"
    CONTAINER_IPV6=$(get_container_ipv6 "$CONTAINER_NAME")
    SUBNET_PREFIX=$(get_host_ipv6_prefix)
    ipv6_address=$(ip addr show | awk '/inet6.*scope global/ { print $2 }' | head -n 1)
    if [[ $ipv6_address == */* ]]; then
        ipv6_length=$(echo "$ipv6_address" | awk -F '/' '{ print $2 }')
        # 尝试从路由器获取真实的 IPv6 前缀长度
        real_ipv6_length=$(get_real_ipv6_prefixlen_from_router "$interface" "$ipv6_length")
        if [ -n "$real_ipv6_length" ] && [ "$real_ipv6_length" != "$ipv6_length" ]; then
            _yellow "Current interface IPv6 prefix: /$ipv6_length, Real prefix from router: /$real_ipv6_length"
            _yellow "当前接口 IPv6 前缀: /$ipv6_length, 从路由器获取的真实前缀: /$real_ipv6_length"
            ipv6_length="$real_ipv6_length"
            ipv6_addr_only=$(echo "$ipv6_address" | cut -d'/' -f1)
            ipv6_address="${ipv6_addr_only}/${ipv6_length}"
        fi
        # 最终安全校验: 前缀长度必须在 1-128 之间，防止任何异常值导致后续 ip addr add 失败
        if ! [[ "$ipv6_length" =~ ^[0-9]+$ ]] || [ "$ipv6_length" -lt 1 ] || [ "$ipv6_length" -gt 128 ]; then
            _yellow "Warning: IPv6 prefix length '$ipv6_length' is out of valid range [1,128], defaulting to 64"
            _yellow "警告: IPv6 前缀长度 '$ipv6_length' 超出有效范围 [1,128]，默认使用 64"
            ipv6_length=64
        fi
        _green "subnet size: $ipv6_length"
        _green "子网大小: $ipv6_length"
    else
        _green "Subnet size for IPV6 not queried"
        _green "查询不到IPV6的子网大小"
        exit 1
    fi
    ipv6_gateway_fe80=$(get_ipv6_gateway_info)
    if [[ $use_iptables == n ]]; then
        setup_network_device_ipv6 "$CONTAINER_NAME" "$CONTAINER_IPV6" "$ipv6_gateway_fe80"
    else
        setup_iptables_ipv6 "$CONTAINER_NAME" "$CONTAINER_IPV6" "$SUBNET_PREFIX" "$ipv6_length" "$interface"
    fi
}

main "$@"
