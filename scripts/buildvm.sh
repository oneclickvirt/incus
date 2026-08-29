#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# 2026.08.30

load_image_lookup() {
    local script_path="${BASH_SOURCE[0]:-$0}"
    local script_dir helper
    script_dir="$(cd "$(dirname "$script_path")" >/dev/null 2>&1 && pwd)"
    for helper in "$script_dir/image_lookup.sh" "/usr/local/bin/image_lookup.sh" "/root/image_lookup.sh"; do
        if [ -f "$helper" ]; then
            # shellcheck source=/dev/null
            . "$helper"
            return 0
        fi
    done
    if command -v curl >/dev/null 2>&1; then
        helper="/tmp/incus_image_lookup_$$.sh"
        if curl -fsSLk "${cdn_success_url:-}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/image_lookup.sh" -o "$helper"; then
            # shellcheck source=/dev/null
            . "$helper"
            rm -f "$helper"
            return 0
        fi
        rm -f "$helper"
    fi
    echo "Missing image_lookup.sh, please download it with this script."
    echo "缺少 image_lookup.sh，请与当前脚本一起下载。"
    exit 1
}

load_image_lookup

created_instance=false
build_succeeded=false
cleanup_failed_instance() {
    local status=$?
    if [ "$created_instance" = true ] && [ "$build_succeeded" != true ] && [ -n "${name:-}" ] && command -v incus >/dev/null 2>&1; then
        incus delete --force "$name" >/dev/null 2>&1 || true
    fi
    return "$status"
}
if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    trap cleanup_failed_instance EXIT
fi

incus_storage_pool() {
    local pool_name="${INCUS_STORAGE_POOL:-}"
    if [ -z "$pool_name" ] && [ -r /usr/local/bin/incus_storage_pool ]; then
        IFS= read -r pool_name </usr/local/bin/incus_storage_pool || true
    fi
    [[ "$pool_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || pool_name="default"
    printf '%s\n' "$pool_name"
}

create_instance_with_tracking() {
    local init_status
    "$@"
    init_status=$?
    if [ "$init_status" -eq 0 ]; then
        created_instance=true
        return 0
    fi
    # The daemon may persist an instance before returning a late init error.
    # Mark that object as ours so the failure trap can remove only this build.
    if incus info "$name" >/dev/null 2>&1; then
        created_instance=true
    fi
    return "$init_status"
}

profile_has_network_device() {
    # Accept both managed-network profiles and profiles attached to a host
    # bridge through `parent`.
    grep -Eq '^[[:space:]]*(network|parent):[[:space:]]*[^[:space:]]+'
}

ensure_incus_ready() {
    storage_pool="$(incus_storage_pool)"
    if ! command -v incus >/dev/null 2>&1; then
        echo "Error: Incus is not installed or not in PATH" >&2
        echo "错误：Incus 未安装或不在 PATH 中" >&2
        return 1
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 incus info >/dev/null 2>&1 || {
            echo "Error: Incus is not initialized; run incus_install.sh successfully first." >&2
            echo "错误：Incus 尚未初始化，请先成功运行 incus_install.sh。" >&2
            return 1
        }
        timeout 15 incus storage show "$storage_pool" >/dev/null 2>&1 || {
            echo "Error: Incus storage pool '$storage_pool' is unavailable." >&2
            echo "错误：Incus 存储池 '$storage_pool' 不可用。" >&2
            return 1
        }
        timeout 15 incus profile show default 2>/dev/null | profile_has_network_device || {
            echo "Error: Incus default profile has no network device." >&2
            echo "错误：Incus default profile 没有网络设备。" >&2
            return 1
        }
    else
        incus info >/dev/null 2>&1 || return 1
        incus storage show "$storage_pool" >/dev/null 2>&1 || return 1
        incus profile show default 2>/dev/null | profile_has_network_device || return 1
    fi
}


check_vm_support() {
    echo "Checking if Incus supports virtual machines..."
    echo "检查Incus是否支持虚拟机..."
    if ! command -v incus >/dev/null 2>&1; then
        echo "Error: Incus is not installed or not in PATH"
        echo "错误：Incus未安装或不在PATH中"
        return 1
    fi
    local drivers
    drivers=$(incus info | grep -i "driver:")
    echo "Available drivers: $drivers"
    echo "可用驱动: $drivers"
    if ! echo "$drivers" | grep -qi "qemu"; then
        echo "Error: Incus does not support virtual machines (qemu driver not found)"
        echo "错误：Incus不支持虚拟机（未找到qemu驱动）"
        echo "Only LXC containers are supported on this system"
        echo "此系统仅支持LXC容器"
        return 1
    fi
    # Detect KVM hardware acceleration availability
    KVM_AVAILABLE=false
    if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            KVM_AVAILABLE=true
            echo "KVM hardware acceleration is available"
            echo "KVM硬件加速可用"
        else
            echo "Warning: /dev/kvm exists but is not accessible, will use QEMU TCG software emulation"
            echo "警告：/dev/kvm存在但不可访问，将使用QEMU TCG软件模拟"
        fi
    else
        echo "Warning: KVM not available (/dev/kvm not found), will use QEMU TCG software emulation (slower)"
        echo "警告：KVM不可用（/dev/kvm未找到），将使用QEMU TCG软件模拟（较慢）"
    fi
    echo "VM support confirmed - qemu driver is available"
    echo "已确认支持虚拟机 - qemu驱动可用"
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

install_dependencies() {
    cd /root >/dev/null 2>&1 || exit 1
    if ! command -v jq; then
        $PACKAGETYPE_INSTALL jq
    fi
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
        echo "Downloading $filename (attempt $attempt/$max_attempts)..."
        echo "正在下载 $filename (尝试 $attempt/$max_attempts)..."
        wget --progress=bar:force "$url" -O "$filename" && return 0
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
        "https://githubapi.spiritlhl.top"
        "https://api.github.com"
        "https://githubapi.spiritlhl.workers.dev"
    )
    for api_url in "${api_urls[@]}"; do
        local response
        if response=$(curl -4 -s -m 6 "${api_url}/repos/oneclickvirt/incus_images/releases/tags/kvm_images") && echo "$response" | jq -e '.assets' >/dev/null 2>&1; then
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
        local image_name
        local kvm_images
        local target_images=()
        local cloud_images=()
        kvm_images="$(get_kvm_images | tr '[:space:]' '\n')"
        if [ -z "$kvm_images" ]; then
            echo "Failed to get KVM images list"
            echo "获取KVM镜像列表失败"
            return 1
        fi
        while IFS= read -r image_name; do
            [ -n "$image_name" ] || continue
            if image_name_matches_system "$image_name" && [[ "$image_name" == *"${sys_bit}"*"kvm.zip" ]]; then
                target_images+=("$image_name")
                if [[ "$image_name" == *"cloud"* ]]; then
                    cloud_images+=("$image_name")
                fi
            fi
        done <<< "$kvm_images"
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
            local short_alias="${a}${b}"
            if [[ "$image_alias_output" != *"$short_alias"* ]]; then
                import_image "$selected_image" "$image_download_url" || return 1
                echo "A matching image exists and will be created using ${image_download_url}"
                echo "匹配的镜像存在，将使用 ${image_download_url} 进行创建"
            else
                system="$short_alias"
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
    local short_alias="${a}${b}"
    if incus image list --format csv | grep -q "^$short_alias,"; then
        echo "Image $short_alias already exists, skipping import"
        echo "镜像 $short_alias 已存在，跳过导入"
        system="$short_alias"
        return 0
    fi
    retry_wget "${cdn_success_url}${image_url}" "$image_name" || return 1
    chmod 755 "$image_name" || return 1
    unzip "$image_name" || return 1
    rm -f -- "$image_name"
    incus image import incus.tar.xz disk.qcow2 --alias "$short_alias" || return 1
    rm -f -- incus.tar.xz disk.qcow2
    system="$short_alias"
}

check_standard_images() {
    status_tuna=false
    system=$(find_remote_image_alias images virtual-machine)
    if [ -n "$system" ]; then
        echo "A matching image exists and will be created using images:${system}"
        echo "匹配的镜像存在，将使用 images:${system} 进行创建"
        fixed_system=false
        return
    fi
    system=$(find_remote_image_alias opsmaru virtual-machine)
    if [ -n "$system" ]; then
        echo "A matching image exists and will be created using opsmaru:${system}"
        echo "匹配的镜像存在，将使用 opsmaru:${system} 进行创建"
        status_tuna=true
        fixed_system=false
    fi
    if [ -z "$image_download_url" ] && [ "$status_tuna" = false ]; then
        echo "No matching image found, please execute"
        echo "incus image list images:system/version_number OR incus image list opsmaru:system/version_number"
        echo "Check if a corresponding image exists"
        echo "未找到匹配的镜像，请执行"
        echo "incus image list images:系统/版本号 或 incus image list opsmaru:系统/版本号"
        echo "查询是否存在对应镜像"
        return 1
    fi
}

create_vm() {
    if incus info "$name" >/dev/null 2>&1; then
        echo "Error: an instance named '$name' already exists." >&2
        echo "错误：名为 '$name' 的实例已存在。" >&2
        return 1
    fi
    rm -f -- "$name" || return 1
    # Explicitly select the pool recorded by the installer.
    if [ -z "$image_download_url" ] && [ "$status_tuna" = true ]; then
        create_instance_with_tracking incus init "opsmaru:${system}" "$name" --vm -c limits.cpu="$cpu" -c limits.memory="$memory"MiB -d root,size="${disk}GiB" -s "${storage_pool:-default}" || return 1
    elif [ -z "$image_download_url" ]; then
        create_instance_with_tracking incus init "images:${system}" "$name" --vm -c limits.cpu="$cpu" -c limits.memory="$memory"MiB -d root,size="${disk}GiB" -s "${storage_pool:-default}" || return 1
    else
        create_instance_with_tracking incus init "$system" "$name" --vm -c limits.cpu="$cpu" -c limits.memory="$memory"MiB -d root,size="${disk}GiB" -s "${storage_pool:-default}" || return 1
    fi
    if ! incus info "$name" >/dev/null 2>&1; then
        echo "VM creation failed, please check the previous output message"
        echo "虚拟机创建失败，请检查前面的输出信息"
        return 1
    fi
}

normalize_template() {
    template=$(echo "${template:-${INCUS_TEMPLATE:-}}" | tr '[:upper:]' '[:lower:]')
}

validate_template() {
    normalize_template
    case "$template" in
    "" | none | web | db | database | dev | development)
        ;;
    *)
        echo "Unknown template: $template"
        echo "未知模板: $template"
        return 1
        ;;
    esac
}

configure_limits() {
    incus config set "$name" limits.cpu.priority 0 || return 1
    incus config set "$name" limits.memory.swap true || return 1
    incus config set "$name" security.secureboot false || return 1
    # If KVM is not available, configure for QEMU TCG software emulation
    if [ "$KVM_AVAILABLE" = false ]; then
        echo "Configuring VM for QEMU TCG software emulation..."
        echo "配置虚拟机使用QEMU TCG软件模拟..."
        incus config set "$name" raw.qemu="-accel tcg,thread=multi -cpu max" || return 1
    fi
}

set_optional_config() {
    local key="$1"
    local value="$2"
    incus config set "$name" "$key" "$value" 2>/dev/null || true
}

apply_template() {
    local selected_template="$template"
    [ -z "$selected_template" ] && return 0
    [ "$selected_template" = "none" ] && return 0

    incus config set "$name" user.incus.template "$selected_template" || return 1
    incus config set "$name" boot.autostart true || return 1
    case "$selected_template" in
    web)
        set_optional_config limits.processes 2048
        ;;
    db | database)
        set_optional_config limits.cpu.priority 5
        set_optional_config limits.memory.swap false
        set_optional_config limits.processes 4096
        ;;
    dev | development)
        set_optional_config limits.processes 4096
        ;;
    *)
        echo "Unknown template: $selected_template"
        echo "未知模板: $selected_template"
        return 1
        ;;
    esac
}

setup_vm() {
    passwd="$(generate_password)"
    incus start "$name" || return 1
    echo "Waiting for VM to start..."
    sleep 30
    max_retries=10
    local vm_ready=false
    for ((i=1; i<=max_retries; i++)); do
        echo "Attempt $i: Waiting for VM to be ready..."
        if incus exec "$name" -- echo "VM is ready" 2>/dev/null; then
            vm_ready=true
            break
        fi
        sleep 10
    done
    if [ "$vm_ready" != true ]; then
        echo "Error: VM did not become ready for configuration." >&2
        return 1
    fi
    if [ ! -x /usr/local/bin/check-dns.sh ]; then
        echo "Error: /usr/local/bin/check-dns.sh is missing; aborting." >&2
        return 1
    fi
    /usr/local/bin/check-dns.sh || return 1
    sleep 3
    if [ "$fixed_system" = false ]; then
        setup_mirror_and_packages || return 1
    fi
    setup_ssh || return 1
    configure_network || return 1
}

setup_mirror_and_packages() {
    if [[ "${CN}" == true ]]; then
        incus exec "$name" -- sh -c 'if command -v yum >/dev/null 2>&1; then yum install -y curl; fi' || return 1
        incus exec "$name" -- sh -c 'if command -v apt-get >/dev/null 2>&1; then apt-get install curl -y --fix-missing; fi' || return 1
        incus exec "$name" -- curl -fLk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh || return 1
        incus exec "$name" -- chmod 755 ChangeMirrors.sh || return 1
        incus exec "$name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips >/dev/null 2>&1 || return 1
        incus exec "$name" -- rm -f -- ChangeMirrors.sh || return 1
    fi
    if echo "$system" | grep -qiE "centos|almalinux|fedora|rocky|oracle"; then
        incus exec "$name" -- sudo yum update -y || return 1
        incus exec "$name" -- sudo yum install -y curl dos2unix || return 1
    elif echo "$system" | grep -qiE "alpine"; then
        incus exec "$name" -- apk update || return 1
        incus exec "$name" -- apk add --no-cache curl || return 1
    elif echo "$system" | grep -qiE "archlinux"; then
        incus exec "$name" -- pacman -Sy --noconfirm --needed curl dos2unix bash || return 1
    else
        incus exec "$name" -- sudo apt-get update -y || return 1
        incus exec "$name" -- sudo apt-get install curl dos2unix -y --fix-missing || return 1
    fi
}

setup_ssh() {
    setup_ssh_bash
}

setup_ssh_bash() {
    if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
        curl -fsSLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh" -o /usr/local/bin/ssh_bash.sh || return 1
        chmod 755 /usr/local/bin/ssh_bash.sh
        dos2unix /usr/local/bin/ssh_bash.sh
    fi
    cp /usr/local/bin/ssh_bash.sh /root || return 1
    incus file push /root/ssh_bash.sh "$name"/root/ || return 1
    incus exec "$name" -- chmod 755 ssh_bash.sh || return 1
    incus exec "$name" -- dos2unix ssh_bash.sh || return 1
    incus exec "$name" -- ./ssh_bash.sh "$passwd" || return 1
    if [ ! -f /usr/local/bin/config.sh ]; then
        curl -fsSLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh" -o /usr/local/bin/config.sh || return 1
        chmod 755 /usr/local/bin/config.sh
        dos2unix /usr/local/bin/config.sh
    fi
    cp /usr/local/bin/config.sh /root || return 1
    incus file push /root/config.sh "$name"/root/ || return 1
    incus exec "$name" -- chmod +x config.sh || return 1
    incus exec "$name" -- dos2unix config.sh || return 1
    incus exec "$name" -- bash config.sh || return 1
    incus exec "$name" -- history -c || return 1
}

wait_for_vm_ready_to_shutdown() {
    echo "Waiting for VM to complete initialization..."
    echo "等待虚拟机完成初始化配置..."
    local max_wait=18
    local check_interval=6
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if incus exec "$name" -- pgrep -f "apt|yum|pacman|apk" > /dev/null 2>&1; then
            echo "VM is executing package management operations, continuing to wait..."
            echo "虚拟机正在执行包管理操作，继续等待..."
        elif incus exec "$name" -- pgrep -f "ssh|sshd|config" > /dev/null 2>&1; then
            echo "VM is executing SSH configuration, continuing to wait..."
            echo "虚拟机正在执行SSH配置，继续等待..."
        fi
        sleep $check_interval
        waited=$((waited + check_interval))
        echo "Waited ${waited} seconds..."
        echo "已等待 ${waited} 秒..."
    done
    if [ $waited -ge $max_wait ]; then
        echo "Wait timeout, forcing shutdown process..."
        echo "等待超时，强制继续关机流程..."
    fi
}

safe_shutdown_vm() {
    echo "Safely shutting down VM..."
    echo "正在安全关闭虚拟机..."
    incus stop "$name" --timeout=30 || return 1
    local max_shutdown_wait=30
    local waited=0
    while [ $waited -lt $max_shutdown_wait ]; do
        local vm_status
        vm_status=$(incus info "$name" 2>/dev/null | grep "Status:" | awk '{print $2}')
        if [ "$vm_status" = "STOPPED" ]; then
            echo "VM has been safely stopped"
            echo "虚拟机已安全停止"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        echo "Waiting for VM to stop... (${waited}/${max_shutdown_wait}s)"
        echo "等待虚拟机停止... (${waited}/${max_shutdown_wait}秒)"
    done
    echo "Error: VM stop timed out; aborting configuration." >&2
    echo "错误：虚拟机停止超时，已中止配置。" >&2
    return 1
}

configure_network() {
    incus restart "$name" || return 1
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
        return 1
    fi
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p' | cut -d/ -f1)
    echo "Host IPv4 address: $ipv4_address"
    if [ -n "$enable_ipv6" ]; then
        if [ "$enable_ipv6" == "y" ]; then
            incus exec "$name" -- /bin/bash -c 'cron_line="*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb"; crontab -l 2>/dev/null | grep -Fqx "$cron_line" || (crontab -l 2>/dev/null; echo "$cron_line") | crontab -' || return 1
            sleep 1
            if [ ! -f "./build_ipv6_network.sh" ]; then
                curl -fsSLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/build_ipv6_network.sh" -o build_ipv6_network.sh || return 1
                chmod +x build_ipv6_network.sh
            fi
            ./build_ipv6_network.sh "$name" || return 1
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
    wait_for_vm_ready_to_shutdown
    safe_shutdown_vm || return 1
    if ((in == out)); then
        speed_limit="$in"
    else
        speed_limit=$(($in > $out ? $in : $out))
    fi
    if ! incus config device override "$name" enp5s0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit 2>/dev/null; then
        incus config device override "$name" eth0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit || return 1
    fi
    if ! incus config device set "$name" enp5s0 ipv4.address "$vm_ip" 2>/dev/null; then
        if ! incus config device override "$name" enp5s0 ipv4.address="$vm_ip" 2>/dev/null; then
            if ! incus config device set "$name" eth0 ipv4.address "$vm_ip" 2>/dev/null; then
                if ! incus config device override "$name" eth0 ipv4.address="$vm_ip" 2>/dev/null; then
                    echo "Error: Failed to apply ipv4.address to network device in VM '$name'." >&2
                    return 1
                fi
            fi
        fi
    fi
    incus config device add "$name" ssh-port proxy "listen=tcp:${ipv4_address}:${sshn}" connect=tcp:0.0.0.0:22 nat=true || return 1
    if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
        incus config device add "$name" nattcp-ports proxy "listen=tcp:${ipv4_address}:${nat1}-${nat2}" "connect=tcp:0.0.0.0:${nat1}-${nat2}" nat=true || return 1
        incus config device add "$name" natudp-ports proxy "listen=udp:${ipv4_address}:${nat1}-${nat2}" "connect=udp:0.0.0.0:${nat1}-${nat2}" nat=true || return 1
    fi
    incus start "$name" || return 1
}

cleanup_and_finish() {
    rm -f -- ssh_bash.sh config.sh ssh_sh.sh
    local record record_tmp
    if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
        record="$name $sshn $passwd $nat1 $nat2"
    elif [ "$nat1" == "0" ] && [ "$nat2" == "0" ]; then
        record="$name $sshn $passwd"
    else
        return 1
    fi
    record_tmp="${name}.tmp.$$"
    if ! printf '%s\n' "$record" >"$record_tmp" || ! mv -f -- "$record_tmp" "$name"; then
        rm -f -- "$record_tmp"
        return 1
    fi
    printf '%s\n' "$record"
    build_succeeded=true
    return 0
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
    template="${12:-${INCUS_TEMPLATE:-}}"
    validate_template || return 1
    check_vm_support || return 1
    ensure_incus_ready || return 1
    if ! normalize_image_system "$system"; then
        echo "Invalid system input: $system"
        echo "系统输入无效: $system"
        return 1
    fi
    system="$normalized_system"
    detect_os
    install_dependencies || return 1
    detect_arch
    check_china
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    check_cdn_file
    handle_image || return 1
    create_vm || return 1
    configure_limits || return 1
    apply_template || return 1
    setup_vm || return 1
    cleanup_and_finish || return 1
}
if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    main "$@"
fi
