#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# cd /root
# ./least.sh NAT服务器前缀 数量
# 2025.08.03

cd /root >/dev/null 2>&1 || exit 1
if [ ! -d "/usr/local/bin" ]; then
    mkdir -p "/usr/local/bin"
fi

check_china() {
    echo "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            echo "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
            CN=true
        fi
    fi
}

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

detect_arch() {
    sysarch="$(uname -m)"
    case "${sysarch}" in
    "x86_64" | "x86" | "amd64" | "x64") sys_bit="x86_64" ;;
    "i386" | "i686") sys_bit="i686" ;;
    "aarch64" | "armv8" | "armv8l") sys_bit="arm64" ;;
    "armv7l") sys_bit="armv7l" ;;
    "s390x") sys_bit="s390x" ;;
    "ppc64le") sys_bit="ppc64le" ;;
    *) sys_bit="x86_64" ;;
    esac
}

retry_wget() {
    local url="$1"
    local filename="$2"
    local max_attempts=5
    local delay=1
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        wget -q "$url" -O "$filename" && return 0
        sleep "$delay"
        delay=$((delay * 2))
    done
    return 1
}

generate_password() {
    local generated=""
    if command -v openssl >/dev/null 2>&1; then
        generated="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)"
    fi
    if [ -z "$generated" ] && [ -r /dev/urandom ]; then
        generated="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    fi
    if [ -z "$generated" ]; then
        generated="$(date +%s%N 2>/dev/null | sha256sum | cut -c 1-16)"
    fi
    echo "$generated"
}

nft_rule_exists() {
    local family="$1"
    local table="$2"
    local chain="$3"
    local pattern="$4"
    nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -F -- "$pattern" >/dev/null 2>&1
}

add_nft_rule_once() {
    local family="$1"
    local table="$2"
    local chain="$3"
    local pattern="$4"
    shift 4
    nft_rule_exists "$family" "$table" "$chain" "$pattern" || nft add rule "$family" "$table" "$chain" "$@" 2>/dev/null || true
}

add_iptables_drop_once() {
    local iface="$1"
    local proto="$2"
    local port="$3"
    iptables --ipv4 -C FORWARD -o "$iface" -p "$proto" --dport "$port" -j DROP 2>/dev/null ||
        iptables --ipv4 -I FORWARD -o "$iface" -p "$proto" --dport "$port" -j DROP 2>/dev/null || true
}

detect_primary_iface() {
    local iface iface_path
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

import_image() {
    local image_name="$1"
    local image_url="$2"
    retry_wget "${cdn_success_url}${image_url}" "$image_name"
    chmod 755 "$image_name"
    unzip "$image_name"
    rm -rf "$image_name"
    incus image import incus.tar.xz rootfs.squashfs --alias "$image_name"
    rm -rf incus.tar.xz rootfs.squashfs
}

create_base_container() {
    local container_name="$1"
    # 根据架构选择对应的镜像URL
    local image_url=""
    if [ "$sys_bit" = "arm64" ]; then
        image_url="https://github.com/oneclickvirt/incus_images/releases/download/debian/debian_11_bullseye_arm64_cloud.zip"
        echo "检测到ARM64架构，使用ARM64镜像"
    elif [ "$sys_bit" = "x86_64" ]; then
        image_url="https://github.com/oneclickvirt/incus_images/releases/download/debian/debian_11_bullseye_x86_64_cloud.zip"
        echo "检测到x86_64架构，使用x86_64镜像"
    fi
    # 尝试下载并导入自定义镜像
    if [ -n "$image_url" ]; then
        echo "正在下载Debian 11镜像..."
        local image_file="debian_11_${sys_bit}_cloud.zip"
        if retry_wget "$image_url" "$image_file"; then
            echo "镜像下载成功，正在导入..."
            chmod 755 "$image_file"
            unzip "$image_file"
            if [ -f "incus.tar.xz" ] && [ -f "rootfs.squashfs" ]; then
                incus image import incus.tar.xz rootfs.squashfs --alias "debian11-${sys_bit}"
                rm -rf incus.tar.xz rootfs.squashfs "$image_file"
                echo "自定义镜像导入成功，创建容器..."
                incus init "debian11-${sys_bit}" "$container_name" -c limits.cpu=1 -c limits.memory=128MiB -s default
                if [ $? -eq 0 ]; then
                    echo "使用自定义镜像创建容器成功"
                    return 0
                fi
            else
                echo "镜像文件解压失败，使用备用方法"
                rm -rf "$image_file" incus.tar.xz rootfs.squashfs 2>/dev/null
            fi
        else
            echo "镜像下载失败，使用备用方法"
        fi
    fi
    # 备用方法：使用原有的镜像源
    echo "使用原有方法创建容器..."
    # 在创建时直接设置磁盘大小限制
    incus init images:debian/11 "$container_name" -c limits.cpu=1 -c limits.memory=128MiB -d root,size=1GiB -s default
    if [ $? -ne 0 ]; then
        incus init opsmaru:debian/11 "$container_name" -c limits.cpu=1 -c limits.memory=128MiB -d root,size=1GiB -s default
    fi
}

setup_storage() {
    local container_name="$1"
    echo "Configuring storage for container: $container_name"
    
    # 磁盘大小已在创建时通过 -d root,size= 设置
    # 此函数保留用于后续可能的其他存储配置
    :
}

configure_resources() {
    local container_name="$1"
    # 设置 IO 限制
    incus config device set "$container_name" root limits.read 5000iops 2>/dev/null || true
    incus config device set "$container_name" root limits.write 5000iops 2>/dev/null || true
    # 设置网络限制
    incus config device override "$container_name" eth0 \
                                limits.egress=300Mbit \
                                limits.ingress=300Mbit \
                                limits.max=300Mbit 2>/dev/null || true
    # 设置 CPU 和内存限制
    incus config set "$container_name" limits.cpu.priority 0
    incus config set "$container_name" limits.cpu.allowance 50%
    incus config set "$container_name" limits.cpu.allowance 25ms/100ms
    incus config set "$container_name" limits.memory.swap true
    incus config set "$container_name" limits.memory.swap.priority 1
    incus config set "$container_name" security.nesting true
}

block_ports() {
    local blocked_ports=(3389 8888 54321 65432)
    # Detect primary outbound interface
    local iface
    iface=$(detect_primary_iface)
    # Try nftables first
    if command -v nft >/dev/null 2>&1; then
        nft add table inet incus_block 2>/dev/null || true
        nft add chain inet incus_block forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || true
        for port in "${blocked_ports[@]}"; do
            add_nft_rule_once inet incus_block forward "oifname \"$iface\" tcp dport $port drop" oifname "$iface" tcp dport "$port" drop
            add_nft_rule_once inet incus_block forward "oifname \"$iface\" udp dport $port drop" oifname "$iface" udp dport "$port" drop
        done
        # Only save our own tables, not incusd's managed 'incus' table
        { nft list table inet incus_masq 2>/dev/null || true; nft list table inet incus_block 2>/dev/null || true; } > /etc/nftables.conf
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
        fi
    else
        # Try to install nftables
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y nftables >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nftables >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nftables >/dev/null 2>&1
        fi
        if command -v nft >/dev/null 2>&1; then
            nft add table inet incus_block 2>/dev/null || true
            nft add chain inet incus_block forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || true
            for port in "${blocked_ports[@]}"; do
                add_nft_rule_once inet incus_block forward "oifname \"$iface\" tcp dport $port drop" oifname "$iface" tcp dport "$port" drop
                add_nft_rule_once inet incus_block forward "oifname \"$iface\" udp dport $port drop" oifname "$iface" udp dport "$port" drop
            done
            # Only save our own tables, not incusd's managed 'incus' table
            { nft list table inet incus_masq 2>/dev/null || true; nft list table inet incus_block 2>/dev/null || true; } > /etc/nftables.conf
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable nftables 2>/dev/null || true
            fi
        else
            # Final fallback: iptables with persistence
            for port in "${blocked_ports[@]}"; do
                add_iptables_drop_once "$iface" tcp "$port"
                add_iptables_drop_once "$iface" udp "$port"
            done
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
            fi
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save 2>/dev/null || true
            fi
            if command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
    fi
}

download_scripts() {
    if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
        curl -fsSLk https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh || exit 1
        chmod 755 /usr/local/bin/ssh_bash.sh
        dos2unix /usr/local/bin/ssh_bash.sh
    fi
    cp /usr/local/bin/ssh_bash.sh /root
    if [ ! -f /usr/local/bin/config.sh ]; then
        curl -fsSLk https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh -o /usr/local/bin/config.sh || exit 1
        chmod 755 /usr/local/bin/config.sh
        dos2unix /usr/local/bin/config.sh
    fi
    cp /usr/local/bin/config.sh /root
}

setup_container() {
    local name="$1"
    local passwd="$2"
    local sshn="$3"
    incus start "$name"
    sleep 1
    if [[ "${CN}" == true ]]; then
        incus exec "$name" -- yum install -y curl
        incus exec "$name" -- apt-get install curl -y --fix-missing
        incus exec "$name" -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        incus exec "$name" -- chmod 755 ChangeMirrors.sh
        incus exec "$name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
        incus exec "$name" -- rm -rf ChangeMirrors.sh
    fi
    incus exec "$name" -- sudo apt-get update -y
    incus exec "$name" -- sudo apt-get install curl -y --fix-missing
    incus exec "$name" -- sudo apt-get install -y --fix-missing dos2unix
    incus file push /root/ssh_bash.sh "$name/root/"
    incus exec "$name" -- chmod 755 ssh_bash.sh
    incus exec "$name" -- dos2unix ssh_bash.sh
    incus exec "$name" -- ./ssh_bash.sh "$passwd"
    incus file push /root/config.sh "$name/root/"
    incus exec "$name" -- chmod +x config.sh
    incus exec "$name" -- dos2unix config.sh
    incus exec "$name" -- bash config.sh
    incus restart "$name"
    echo "Waiting for the container to start. Attempting to retrieve the container's IP address..."
    max_retries=3
    delay=5
    for ((i=1; i<=max_retries; i++)); do
        echo "Attempt $i: Waiting $delay seconds before retrieving container info..."
        sleep $delay
        container_ip=$(incus list "$name" --format json | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet") | .address')
        if [[ -n "$container_ip" ]]; then
            echo "Container IPv4 address: $container_ip"
            break
        fi
        delay=$((delay * 2))
    done
    if [[ -z "$container_ip" ]]; then
        echo "Error: Container failed to start or no IP address was assigned."
        exit 1
    fi
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p' | cut -d/ -f1)
    echo "Host IPv4 address: $ipv4_address"
    incus stop "$name"
    sleep 0.5
    if ! incus config device set "$name" eth0 ipv4.address "$container_ip" 2>/dev/null; then
        if ! incus config device override "$name" eth0 ipv4.address="$container_ip" 2>/dev/null; then
            echo "Error: Failed to apply ipv4.address to device 'eth0' in container '$name'." >&2
            exit 1
        fi
    fi
    incus config device add "$name" ssh-port proxy listen=tcp:$ipv4_address:$sshn connect=tcp:0.0.0.0:22 nat=true
    incus start "$name"
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=$sshn/tcp
        firewall-cmd --reload
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow ${sshn}/tcp
        ufw reload
    fi
    echo "$name $sshn $passwd" >>log
}

create_containers() {
    local base_name="$1"
    local count="$2"
    for ((a = 1; a <= count; a++)); do
        local container_name="${base_name}${a}"
        local ssh_port=$((20000 + a))
        local password
        password="$(generate_password)"
        incus copy "$base_name" "$container_name"
        setup_container "$container_name" "$password" "$ssh_port"
    done
}

main() {
    local base_name="$1"
    local count="$2"
    rm -rf log
    check_china
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    detect_arch
    create_base_container "$base_name"
    setup_storage "$base_name"
    configure_resources "$base_name"
    block_ports
    download_scripts
    create_containers "$base_name" "$count"
    rm -rf ssh_bash.sh config.sh ssh_sh.sh
}
main "$1" "$2"
