#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# cd /root
# ./least.sh NAT服务器前缀 数量
# 2025.05.31

cd /root >/dev/null 2>&1
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

check_cdn_file() {
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

import_image() {
    local image_name="$1"
    local image_url="$2"
    retry_wget "${cdn_success_url}${image_url}" "$image_name"
    chmod 777 "$image_name"
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
            chmod 777 "$image_file"
            unzip "$image_file"
            if [ -f "incus.tar.xz" ] && [ -f "rootfs.squashfs" ]; then
                incus image import incus.tar.xz rootfs.squashfs --alias "debian11-${sys_bit}"
                rm -rf incus.tar.xz rootfs.squashfs "$image_file"
                echo "自定义镜像导入成功，创建容器..."
                incus init "debian11-${sys_bit}" "$container_name" -c limits.cpu=1 -c limits.memory=128MiB
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
    incus init images:debian/11 "$container_name" -c limits.cpu=1 -c limits.memory=128MiB
    if [ $? -ne 0 ]; then
        incus init opsmaru:debian/11 "$container_name" -c limits.cpu=1 -c limits.memory=128MiB
    fi
}

setup_storage() {
    local container_name="$1"
    if [ -f /usr/local/bin/incus_storage_type ]; then
        storage_type=$(cat /usr/local/bin/incus_storage_type)
    else
        storage_type="btrfs"
    fi
    incus storage create "$container_name" "$storage_type" size=200MB >/dev/null 2>&1
}

configure_resources() {
    local container_name="$1"
    incus config device override "$container_name" root size=200MB
    incus config device set "$container_name" root limits.read 500MB
    incus config device set "$container_name" root limits.write 500MB
    incus config device set "$container_name" root limits.read 5000iops
    incus config device set "$container_name" root limits.write 5000iops
    incus config device set "$container_name" root limits.max 300MB
    incus config device override "$container_name" eth0 limits.egress=300Mbit
    incus config device override "$container_name" eth0 limits.ingress=300Mbit
    incus config device override "$container_name" eth0 limits.max=300Mbit
    incus config set "$container_name" limits.cpu.priority 0
    incus config set "$container_name" limits.cpu.allowance 50%
    incus config set "$container_name" limits.cpu.allowance 25ms/100ms
    incus config set "$container_name" limits.memory.swap true
    incus config set "$container_name" limits.memory.swap.priority 1
    incus config set "$container_name" security.nesting true
}

block_ports() {
    blocked_ports=(3389 8888 54321 65432)
    for port in "${blocked_ports[@]}"; do
        iptables --ipv4 -I FORWARD -o eth0 -p tcp --dport ${port} -j DROP
        iptables --ipv4 -I FORWARD -o eth0 -p udp --dport ${port} -j DROP
    done
}

download_scripts() {
    if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh
        chmod 777 /usr/local/bin/ssh_bash.sh
        dos2unix /usr/local/bin/ssh_bash.sh
    fi
    cp /usr/local/bin/ssh_bash.sh /root
    if [ ! -f /usr/local/bin/config.sh ]; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh -o /usr/local/bin/config.sh
        chmod 777 /usr/local/bin/config.sh
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
        incus exec "$name" -- chmod 777 ChangeMirrors.sh
        incus exec "$name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
        incus exec "$name" -- rm -rf ChangeMirrors.sh
    fi
    incus exec "$name" -- sudo apt-get update -y
    incus exec "$name" -- sudo apt-get install curl -y --fix-missing
    incus exec "$name" -- sudo apt-get install -y --fix-missing dos2unix
    incus file push /root/ssh_bash.sh "$name/root/"
    incus exec "$name" -- chmod 777 ssh_bash.sh
    incus exec "$name" -- dos2unix ssh_bash.sh
    incus exec "$name" -- sudo ./ssh_bash.sh $passwd
    incus file push /root/config.sh "$name/root/"
    incus exec "$name" -- chmod +x config.sh
    incus exec "$name" -- dos2unix config.sh
    incus exec "$name" -- bash config.sh
    incus config device add "$name" ssh-port proxy listen=tcp:0.0.0.0:$sshn connect=tcp:127.0.0.1:22
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
        local ori=$(date | md5sum)
        local password=${ori:2:9}
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