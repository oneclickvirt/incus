#!/bin/bash
# by hhttps://github.com/oneclickvirt/incus
# 2025.05.18

# 字体颜色函数
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 设置环境变量
setup_environment() {
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

# 检测操作系统类型
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
        centos | almalinux | rockylinux)
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
        esac
    fi
    if [ -z "${PACKAGETYPE:-}" ]; then
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
        fi
    fi
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
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

# 检查CDN文件
check_cdn_file() {
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
    sysctl_config="$1"
    if grep -q "^$sysctl_config" /etc/sysctl.conf; then
        if grep -q "^#$sysctl_config" /etc/sysctl.conf; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
        fi
    else
        echo "$sysctl_config" >>/etc/sysctl.conf
    fi
}

# 等待容器启动
wait_for_container_running() {
    local container_name=$1
    local timeout=24
    local interval=3
    local elapsed_time=0
    while [ $elapsed_time -lt $timeout ]; do
        status=$(incus info "$container_name" | grep "Status: RUNNING")
        if [[ "$status" == *RUNNING* ]]; then
            break
        fi
        echo "Waiting for the conatiner "$container_name" to run..."
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
        status=$(incus info "$container_name" | grep "Status: STOPPED")
        if [[ "$status" == *STOPPED* ]]; then
            break
        fi
        echo "Waiting for the conatiner "$container_name" to stop..."
        echo "${status}"
        sleep $interval
        elapsed_time=$((elapsed_time + interval))
    done
}

# 获取容器内网IPv6地址
get_container_ipv6() {
    local container_name=$1
    local ipv6=$(incus list $container_name --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet6") | select(.scope=="global") | .address')
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
    local prefix=$(ip -6 addr show | grep -E 'inet6.*global' | awk '{print $2}' | awk -F'/' '{print $1}' | head -n 1 | cut -d ':' -f1-5):
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
    local output=$(ip -6 route show | awk '/default via/{print $3}')
    local num_lines=$(echo "$output" | wc -l)
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
    if [[ "$OS" == "almalinux" && "$VERSION" =~ ^9 ]]; then
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            SIPCALC_URL="https://dl.fedoraproject.org/pub/epel/8/Everything/x86_64/Packages/s/sipcalc-1.1.6-17.el8.x86_64.rpm"
        elif [[ "$ARCH" == "aarch64" ]]; then
            SIPCALC_URL="https://dl.fedoraproject.org/pub/epel/8/Everything/aarch64/Packages/s/sipcalc-1.1.6-17.el8.aarch64.rpm"
        else
            echo "Unsupported architecture: $ARCH"
            exit 1
        fi
        echo "AlmaLinux 9 detected — installing sipcalc from EPEL 8 ($ARCH)"
        curl -LO "$SIPCALC_URL"
        sudo dnf install -y "./$(basename "$SIPCALC_URL")"
        rm -f "./$(basename "$SIPCALC_URL")"
    else
        install_package sipcalc
    fi
    if [ ! -f /usr/local/bin/incus_check_ipv6 ] || [ ! -s /usr/local/bin/incus_check_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/incus_check_ipv6)" = "" ]; then
        check_ipv6
    fi
    IPV6=$(cat /usr/local/bin/incus_check_ipv6)
    if ip -f inet6 addr | grep -q "he-ipv6"; then
        ipv6_network_name="he-ipv6"
        ip_network_gam=$(ip -6 addr show ${ipv6_network_name} | grep -E "${IPV6}/24|${IPV6}/48|${IPV6}/64|${IPV6}/80|${IPV6}/96|${IPV6}/112" | grep global | awk '{print $2}' 2>/dev/null)
    else
        ipv6_network_name=$(ls /sys/class/net/ | grep -v "$(ls /sys/devices/virtual/net/)")
        ip_network_gam=$(ip -6 addr show ${ipv6_network_name} | grep global | awk '{print $2}' | head -n 1)
    fi
    _yellow "Local IPV6 address: $ip_network_gam"
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
        incus config device add "$container_name" eth1 nic nictype=routed parent=${ipv6_network_name} ipv6.address=${incus_ipv6}
        sleep 3
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=trusted --add-interface=${ipv6_network_name}
            firewall-cmd --reload
        elif command -v ufw >/dev/null 2>&1; then
            ufw allow in on ${ipv6_network_name}
            ufw allow out on ${ipv6_network_name}
            ufw reload
        fi
        incus start "$container_name"
        if [[ "${ipv6_gateway_fe80}" == "N" ]]; then
            inter=$(ls /sys/class/net/ | grep -v "$(ls /sys/devices/virtual/net/)")
            del_ip=$(ip -6 addr show dev ${inter} | awk '/inet6 fe80/ {print $2}')
            if [ -n "$del_ip" ]; then
                ip addr del ${del_ip} dev ${inter}
                echo '#!/bin/bash' >/usr/local/bin/remove_route.sh
                echo "ip addr del ${del_ip} dev ${inter}" >>/usr/local/bin/remove_route.sh
                chmod 777 /usr/local/bin/remove_route.sh
                if ! crontab -l | grep -q '/usr/local/bin/remove_route.sh' &>/dev/null; then
                    echo '@reboot /usr/local/bin/remove_route.sh' | crontab -
                fi
            fi
        fi
        if ! crontab -l | grep -q '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb'; then
            echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -
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
    local use_firewalld=false
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        use_firewalld=true
    fi
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
    check_cdn_file
    for i in $(seq 3 65535); do
        IPV6="${subnet_prefix}$i"
        [[ $IPV6 == $container_ipv6 ]] && continue
        ip -6 addr show dev "$interface" | grep -qw "$IPV6" && continue
        if ! ping6 -c1 -w1 -q "$IPV6" &>/dev/null; then
            if ! ip6tables -t nat -C PREROUTING -d "$IPV6" -j DNAT --to-destination "$container_ipv6" &>/dev/null; then
                _green "$IPV6"
                break
            fi
        fi
        _yellow "$IPV6"
    done
    if [ -z "$IPV6" ]; then
        _red "No IPV6 address available, no auto mapping"
        _red "无可用 IPV6 地址，不进行自动映射"
        exit 1
    fi
    ip addr add "$IPV6"/"$ipv6_length" dev "$interface"
    if [ "$use_firewalld" = true ]; then
        systemctl enable --now firewalld
        sleep 3
        firewall-cmd --permanent --direct --add-rule ipv6 nat PREROUTING 0 -d $IPV6 -j DNAT --to-destination $container_ipv6
        firewall-cmd --reload
    else
        ip6tables -t nat -A PREROUTING -d $IPV6 -j DNAT --to-destination $container_ipv6
    fi
    if [ ! -f /usr/local/bin/add-ipv6.sh ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/incus/main/scripts/add-ipv6.sh -O /usr/local/bin/add-ipv6.sh
        chmod +x /usr/local/bin/add-ipv6.sh
    else
        echo "Script already exists. Skipping installation."
    fi
    if [ ! -f /etc/systemd/system/add-ipv6.service ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/incus/main/scripts/add-ipv6.service -O /etc/systemd/system/add-ipv6.service
        chmod +x /etc/systemd/system/add-ipv6.service
        systemctl daemon-reload
        systemctl enable --now add-ipv6.service
    else
        echo "Service already exists. Skipping installation."
    fi
    mkdir -p /etc/iptables
    ip6tables-save >/etc/iptables/rules.v6
    if command -v apt >/dev/null 2>&1; then
        install_package netfilter-persistent
        netfilter-persistent save
        netfilter-persistent reload
        service netfilter-persistent restart
    elif [ "$use_firewalld" = true ]; then
        systemctl restart firewalld
    else
        echo "Unsupported system: cannot persist ip6tables rules"
        exit 1
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
    wait_for_container_running "$CONTAINER_NAME"
    CONTAINER_IPV6=$(get_container_ipv6 "$CONTAINER_NAME")
    SUBNET_PREFIX=$(get_host_ipv6_prefix)
    ipv6_address=$(ip addr show | awk '/inet6.*scope global/ { print $2 }' | head -n 1)
    if [[ $ipv6_address == */* ]]; then
        ipv6_length=$(echo "$ipv6_address" | awk -F '/' '{ print $2 }')
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
