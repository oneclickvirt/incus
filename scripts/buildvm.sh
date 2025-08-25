#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# 2025.08.25

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
            VERSION=""
            PACKAGETYPE="pacman"
            PACKAGETYPE_INSTALL="pacman -S --noconfirm --needed"
            PACKAGETYPE_UPDATE="pacman -Sy"
            PACKAGETYPE_REMOVE="pacman -Rsc --noconfirm"
            PACKAGETYPE_ONLY_REMOVE="pacman -Rdd --noconfirm"
            ;;
        manjaro | manjaro-arm)
            OS="manjaro"
            VERSION=""
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

install_dependencies() {
    cd /root >/dev/null 2>&1
    if ! command -v jq; then
        $PACKAGETYPE_INSTALL jq
    fi
}

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

retry_curl() {
    local url="$1"
    local max_attempts=5
    local delay=1
    _retry_result=""
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        _retry_result=$(curl -slk -m 6 "$url")
        if [ $? -eq 0 ] && [ -n "$_retry_result" ]; then
            return 0
        fi
        sleep "$delay"
        delay=$((delay * 2))
    done
    return 1
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

get_kvm_images() {
    local api_urls=(
        "https://api.github.com"
        "https://githubapi.spiritlhl.workers.dev"
        "https://githubapi.spiritlhl.top"
    )
    
    for api_url in "${api_urls[@]}"; do
        local response=$(curl -s -m 10 "${api_url}/repos/oneclickvirt/incus_images/releases/tags/kvm_images")
        if [ $? -eq 0 ] && echo "$response" | jq -e '.assets' >/dev/null 2>&1; then
            echo "$response" | jq -r '.assets[].name'
            return 0
        fi
        sleep 1
    done
    return 1
}

handle_image() {
    image_download_url=""
    fixed_system=false
    if [[ "$sys_bit" == "x86_64" || "$sys_bit" == "arm64" ]]; then
        local kvm_images=($(get_kvm_images))
        if [ ${#kvm_images[@]} -eq 0 ]; then
            echo "Failed to get KVM images list"
            echo "获取KVM镜像列表失败"
            exit 1
        fi
        
        local target_images=()
        local cloud_images=()
        
        for image_name in "${kvm_images[@]}"; do
            if [ -z "${b}" ]; then
                if [[ "$image_name" == "${a}"*"${sys_bit}"*"kvm.zip" ]]; then
                    target_images+=("$image_name")
                    if [[ "$image_name" == *"cloud"* ]]; then
                        cloud_images+=("$image_name")
                    fi
                fi
            else
                if [[ "$image_name" == "${a}_${b}"*"${sys_bit}"*"kvm.zip" ]]; then
                    target_images+=("$image_name")
                    if [[ "$image_name" == *"cloud"* ]]; then
                        cloud_images+=("$image_name")
                    fi
                fi
            fi
        done
        
        local selected_image=""
        if [ ${#cloud_images[@]} -gt 0 ]; then
            selected_image="${cloud_images[0]}"
        elif [ ${#target_images[@]} -gt 0 ]; then
            selected_image="${target_images[0]}"
        fi
        
        if [ -n "$selected_image" ]; then
            fixed_system=true
            image_download_url="https://github.com/oneclickvirt/incus_images/releases/download/kvm_images/${selected_image}"
            image_alias_output=$(incus image alias list)
            if [[ "$image_alias_output" != *"$selected_image"* ]]; then
                import_image "$selected_image" "$image_download_url"
                echo "A matching image exists and will be created using ${image_download_url}"
                echo "匹配的镜像存在，将使用 ${image_download_url} 进行创建"
            fi
        fi
    fi
    
    if [ -z "$image_download_url" ]; then
        check_standard_images
    fi
}

import_image() {
    local image_name="$1"
    local image_url="$2"
    retry_wget "${cdn_success_url}${image_url}" "$image_name"
    chmod 777 "$image_name"
    unzip "$image_name"
    rm -rf "$image_name"
    incus image import incus.tar.xz disk.qcow2 --alias "$image_name"
    rm -rf incus.tar.xz disk.qcow2
}

check_standard_images() {
    system=$(incus image list images:${a}/${b} --format=json | jq -r --arg ARCHITECTURE "$sys_bit" '.[] | select(.type == "virtual-machine" and .architecture == $ARCHITECTURE) | .aliases[0].name' | head -n 1)
    if [ -n "$system" ]; then
        echo "A matching image exists and will be created using images:${system}"
        echo "匹配的镜像存在，将使用 images:${system} 进行创建"
        fixed_system=false
        return
    fi
    system=$(incus image list opsmaru:${a}/${b} --format=json | jq -r --arg ARCHITECTURE "$sys_bit" '.[] | select(.type == "virtual-machine" and .architecture == $ARCHITECTURE) | .aliases[0].name' | head -n 1)
    if [ $? -ne 0 ]; then
        status_tuna=false
    else
        if echo "$system" | grep -q "${a}"; then
            echo "A matching image exists and will be created using opsmaru:${system}"
            echo "匹配的镜像存在，将使用 opsmaru:${system} 进行创建"
            status_tuna=true
            fixed_system=false
        else
            status_tuna=false
        fi
    fi
    if [ -z "$image_download_url" ] && [ "$status_tuna" = false ]; then
        echo "No matching image found, please execute"
        echo "incus image list images:system/version_number OR incus image list opsmaru:system/version_number"
        echo "Check if a corresponding image exists"
        echo "未找到匹配的镜像，请执行"
        echo "incus image list images:系统/版本号 或 incus image list opsmaru:系统/版本号"
        echo "查询是否存在对应镜像"
        exit 1
    fi
}

create_vm() {
    rm -rf "$name"
    if [ -z "$image_download_url" ] && [ "$status_tuna" = true ]; then
        incus init opsmaru:${system} "$name" --vm -c limits.cpu="$cpu" -c limits.memory="$memory"MiB
    elif [ -z "$image_download_url" ]; then
        incus init images:${system} "$name" --vm -c limits.cpu="$cpu" -c limits.memory="$memory"MiB
    else
        incus init "$selected_image" "$name" --vm -c limits.cpu="$cpu" -c limits.memory="$memory"MiB
    fi
    if [ $? -ne 0 ]; then
        echo "VM creation failed, please check the previous output message"
        echo "虚拟机创建失败，请检查前面的输出信息"
        exit 1
    fi
}

configure_storage() {
    if [ -f /usr/local/bin/incus_storage_type ]; then
        storage_type=$(cat /usr/local/bin/incus_storage_type)
    else
        storage_type="btrfs"
    fi
    if [[ $disk == *.* ]]; then
        disk_mb=$(echo "$disk * 1024" | bc | cut -d '.' -f 1)
        incus config device override "$name" root size="$disk_mb"MB
    else
        incus config device override "$name" root size="$disk"GB
    fi
}

configure_limits() {
    incus config set "$name" limits.cpu.priority 0
    incus config set "$name" limits.memory.swap true
    incus config set "$name" security.secureboot false
}

setup_vm() {
    ori=$(date | md5sum)
    passwd=${ori:2:9}
    incus start "$name"
    echo "Waiting for VM to start..."
    sleep 30
    
    max_retries=10
    for ((i=1; i<=max_retries; i++)); do
        echo "Attempt $i: Waiting for VM to be ready..."
        if incus exec "$name" -- echo "VM is ready" 2>/dev/null; then
            break
        fi
        sleep 10
    done
    
    chmod 777 /usr/local/bin/check-dns.sh
    /usr/local/bin/check-dns.sh
    sleep 3
    
    if [ "$fixed_system" = false ]; then
        setup_mirror_and_packages
    fi
    setup_ssh
    configure_network
}

setup_mirror_and_packages() {
    if [[ "${CN}" == true ]]; then
        incus exec "$name" -- yum install -y curl
        incus exec "$name" -- apt-get install curl -y --fix-missing
        incus exec "$name" -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        incus exec "$name" -- chmod 777 ChangeMirrors.sh
        incus exec "$name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null > /dev/null
        incus exec "$name" -- rm -rf ChangeMirrors.sh
    fi
    if echo "$system" | grep -qiE "centos|almalinux|fedora|rocky|oracle"; then
        incus exec "$name" -- sudo yum update -y
        incus exec "$name" -- sudo yum install -y curl
        incus exec "$name" -- sudo yum install -y dos2unix
    elif echo "$system" | grep -qiE "alpine"; then
        incus exec "$name" -- apk update
        incus exec "$name" -- apk add --no-cache curl
    elif echo "$system" | grep -qiE "archlinux"; then
        incus exec "$name" -- pacman -Sy
        incus exec "$name" -- pacman -Sy --noconfirm --needed curl
        incus exec "$name" -- pacman -Sy --noconfirm --needed dos2unix
        incus exec "$name" -- pacman -Sy --noconfirm --needed bash
    else
        incus exec "$name" -- sudo apt-get update -y
        incus exec "$name" -- sudo apt-get install curl -y --fix-missing
        incus exec "$name" -- sudo apt-get install dos2unix -y --fix-missing
    fi
}

setup_ssh() {
    setup_ssh_bash
}

setup_ssh_bash() {
    if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
        curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh
        chmod 777 /usr/local/bin/ssh_bash.sh
        dos2unix /usr/local/bin/ssh_bash.sh
    fi
    cp /usr/local/bin/ssh_bash.sh /root
    incus file push /root/ssh_bash.sh "$name"/root/
    incus exec "$name" -- chmod 777 ssh_bash.sh
    incus exec "$name" -- dos2unix ssh_bash.sh
    incus exec "$name" -- sudo ./ssh_bash.sh $passwd
    if [ ! -f /usr/local/bin/config.sh ]; then
        curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh -o /usr/local/bin/config.sh
        chmod 777 /usr/local/bin/config.sh
        dos2unix /usr/local/bin/config.sh
    fi
    cp /usr/local/bin/config.sh /root
    incus file push /root/config.sh "$name"/root/
    incus exec "$name" -- chmod +x config.sh
    incus exec "$name" -- dos2unix config.sh
    incus exec "$name" -- bash config.sh
    incus exec "$name" -- history -c
}

configure_network() {
    incus restart "$name"
    echo "Waiting for the VM to start. Attempting to retrieve the VM's IP address..."
    max_retries=5
    delay=10
    for ((i=1; i<=max_retries; i++)); do
        echo "Attempt $i: Waiting $delay seconds before retrieving VM info..."
        sleep $delay
        vm_ip=$(incus list "$name" --format json | jq -r '.[0].state.network.enp5s0.addresses[]? | select(.family=="inet") | .address' 2>/dev/null)
        if [[ -z "$vm_ip" ]]; then
            vm_ip=$(incus list "$name" --format json | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet") | .address' 2>/dev/null)
        fi
        if [[ -n "$vm_ip" ]]; then
            echo "VM IPv4 address: $vm_ip"
            break
        fi
        delay=$((delay + 5))
    done
    if [[ -z "$vm_ip" ]]; then
        echo "Error: VM failed to start or no IP address was assigned."
        exit 1
    fi
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p' | cut -d/ -f1)
    echo "Host IPv4 address: $ipv4_address"
    if [ -n "$enable_ipv6" ]; then
        if [ "$enable_ipv6" == "y" ]; then
            incus exec "$name" -- echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -
            sleep 1
            if [ ! -f "./build_ipv6_network.sh" ]; then
                curl -L ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/build_ipv6_network.sh -o build_ipv6_network.sh
                chmod +x build_ipv6_network.sh
            fi
            ./build_ipv6_network.sh "$name"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${sshn}/tcp
        if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
            firewall-cmd --permanent --add-port=${nat1}-${nat2}/tcp
            firewall-cmd --permanent --add-port=${nat1}-${nat2}/udp
        fi
        firewall-cmd --reload
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow ${sshn}/tcp
        if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
            ufw allow ${nat1}:${nat2}/tcp
            ufw allow ${nat1}:${nat2}/udp
        fi
        ufw reload
    fi
    incus stop "$name"
    sleep 0.5
    if ((in == out)); then
        speed_limit="$in"
    else
        speed_limit=$(($in > $out ? $in : $out))
    fi
    incus config device override "$name" enp5s0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit 2>/dev/null || \
    incus config device override "$name" eth0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit
    
    if ! incus config device set "$name" enp5s0 ipv4.address "$vm_ip" 2>/dev/null; then
        if ! incus config device override "$name" enp5s0 ipv4.address="$vm_ip" 2>/dev/null; then
            if ! incus config device set "$name" eth0 ipv4.address "$vm_ip" 2>/dev/null; then
                if ! incus config device override "$name" eth0 ipv4.address="$vm_ip" 2>/dev/null; then
                    echo "Error: Failed to apply ipv4.address to network device in VM '$name'." >&2
                    exit 1
                fi
            fi
        fi
    fi
    incus config device add "$name" ssh-port proxy listen=tcp:$ipv4_address:$sshn connect=tcp:0.0.0.0:22 nat=true
    if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
        incus config device add "$name" nattcp-ports proxy listen=tcp:$ipv4_address:$nat1-$nat2 connect=tcp:0.0.0.0:$nat1-$nat2 nat=true
        incus config device add "$name" natudp-ports proxy listen=udp:$ipv4_address:$nat1-$nat2 connect=udp:0.0.0.0:$nat1-$nat2 nat=true
    fi
    incus start "$name"
}

cleanup_and_finish() {
    rm -rf ssh_bash.sh config.sh ssh_sh.sh
    if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
        echo "$name $sshn $passwd $nat1 $nat2" >>"$name"
        echo "$name $sshn $passwd $nat1 $nat2"
        exit 1
    fi
    if [ "$nat1" == "0" ] && [ "$nat2" == "0" ]; then
        echo "$name $sshn $passwd" >>"$name"
        echo "$name $sshn $passwd"
    fi
}

main() {
    name="${1:-test}"
    cpu="${2:-1}"
    memory="${3:-512}"
    disk="${4:-10}"
    sshn="${5:-20001}"
    nat1="${6:-20002}"
    nat2="${7:-20025}"
    in="${8:-10240}"
    out="${9:-10240}"
    enable_ipv6="${10:-N}"
    enable_ipv6=$(echo "$enable_ipv6" | tr '[:upper:]' '[:lower:]')
    system="${11:-debian11}"
    a="${system%%[0-9]*}"
    b="${system##*[!0-9.]}"
    detect_os
    install_dependencies
    detect_arch
    check_china
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    handle_image
    create_vm
    configure_storage
    configure_limits
    setup_vm
    cleanup_and_finish
}
main "$@"