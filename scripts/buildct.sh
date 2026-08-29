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

# A failed create/configure operation must never fall through to the remaining
# steps.  Keep the cleanup scoped to instances created by this invocation.
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
    # Incus can persist the instance before a late error is returned (for
    # example, while applying the profile or storage device). Treat that
    # object as owned by this invocation so the EXIT cleanup removes it.
    if incus info "$name" >/dev/null 2>&1; then
        created_instance=true
    fi
    return "$init_status"
}

profile_has_network_device() {
    # Profiles backed by a managed bridge use `network`; profiles attached to
    # an existing host bridge use `parent`. Both are valid IPv6 setups.
    grep -Eq '^[[:space:]]*(network|parent):[[:space:]]*[^[:space:]]+'
}

ensure_incus_ready() {
    local probe="incus"
    storage_pool="$(incus_storage_pool)"
    if ! command -v incus >/dev/null 2>&1; then
        echo "Error: Incus is not installed or not in PATH" >&2
        echo "错误：Incus 未安装或不在 PATH 中" >&2
        return 1
    fi
    if command -v timeout >/dev/null 2>&1; then
        probe="timeout 15 incus"
    fi
    if ! $probe info >/dev/null 2>&1; then
        echo "Error: Incus is not initialized; run incus_install.sh successfully first." >&2
        echo "错误：Incus 尚未初始化，请先成功运行 incus_install.sh。" >&2
        return 1
    fi
    if ! $probe storage show "$storage_pool" >/dev/null 2>&1; then
        echo "Error: Incus storage pool '$storage_pool' is unavailable." >&2
        echo "错误：Incus 存储池 '$storage_pool' 不可用。" >&2
        return 1
    fi
    if ! $probe profile show default 2>/dev/null | profile_has_network_device; then
        echo "Error: Incus default profile has no network device." >&2
        echo "错误：Incus default profile 没有网络设备。" >&2
        return 1
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

handle_image() {
    image_download_url=""
    fixed_system=false
    if [[ "$sys_bit" == "x86_64" || "$sys_bit" == "arm64" ]]; then
        if retry_curl "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus_images/main/${sys_bit}_all_images.txt"; then
            image_name=$(
                printf '%s\n' "$_retry_result" |
                    tr '[:space:]' '\n' |
                    find_matching_image_from_stream
            )
            if [ -n "$image_name" ]; then
                fixed_system=true
                image_download_url="https://github.com/oneclickvirt/incus_images/releases/download/${a}/${image_name}"
                image_alias_output=$(incus image alias list)
                if [[ "$image_alias_output" != *"$image_name"* ]]; then
                    import_image "$image_name" "$image_download_url" || return 1
                    echo "A matching image exists and will be created using ${image_download_url}"
                    echo "匹配的镜像存在，将使用 ${image_download_url} 进行创建"
                fi
            fi
        fi
    else
        incus image list "images:$(remote_image_query)" >/dev/null 2>&1 || true
    fi
    if [ -z "$image_download_url" ]; then
        check_standard_images
    fi
}

import_image() {
    local image_name="$1"
    local image_url="$2"
    retry_wget "${cdn_success_url}${image_url}" "$image_name" || return 1
    chmod 755 "$image_name" || return 1
    unzip "$image_name" || return 1
    rm -f -- "$image_name"
    incus image import incus.tar.xz rootfs.squashfs --alias "$image_name" || return 1
    rm -f -- incus.tar.xz rootfs.squashfs
}

check_standard_images() {
    status_tuna=false
    system=$(find_remote_image_alias images container)
    if [ -n "$system" ]; then
        echo "A matching image exists and will be created using images:${system}"
        echo "匹配的镜像存在，将使用 images:${system} 进行创建"
        fixed_system=false
        return
    fi
    system=$(find_remote_image_alias opsmaru container)
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

create_container() {
    if incus info "$name" >/dev/null 2>&1; then
        echo "Error: an instance named '$name' already exists." >&2
        echo "错误：名为 '$name' 的实例已存在。" >&2
        return 1
    fi
    rm -f -- "$name" || return 1
    # 使用安装器记录的存储池创建容器，并直接设置磁盘大小限制
    local disk_size
    if [[ $disk == *.* ]]; then
        disk_mb=$(echo "$disk * 1024" | bc | cut -d '.' -f 1)
        disk_size="${disk_mb}MiB"
    else
        disk_size="${disk}GiB"
    fi
    
    if [ -z "$image_download_url" ] && [ "$status_tuna" = true ]; then
        if ! create_instance_with_tracking incus init "opsmaru:${system}" "$name" -c limits.cpu="$cpu" -c limits.memory="$memory"MiB -d root,size="${disk_size}" -s "${storage_pool:-default}"; then
            echo "Container creation failed, please check the previous output message" >&2
            echo "容器创建失败，请检查前面的输出信息" >&2
            return 1
        fi
    elif [ -z "$image_download_url" ]; then
        if ! create_instance_with_tracking incus init "images:${system}" "$name" -c limits.cpu="$cpu" -c limits.memory="$memory"MiB -d root,size="${disk_size}" -s "${storage_pool:-default}"; then
            echo "Container creation failed, please check the previous output message" >&2
            echo "容器创建失败，请检查前面的输出信息" >&2
            return 1
        fi
    else
        if ! create_instance_with_tracking incus init "$image_name" "$name" -c limits.cpu="$cpu" -c limits.memory="$memory"MiB -d root,size="${disk_size}" -s "${storage_pool:-default}"; then
            echo "Container creation failed, please check the previous output message" >&2
            echo "容器创建失败，请检查前面的输出信息" >&2
            return 1
        fi
    fi
    if ! incus info "$name" >/dev/null 2>&1; then
        echo "Container creation failed, please check the previous output message"
        echo "容器创建失败，请检查前面的输出信息"
        return 1
    fi
}

configure_storage() {
    # 磁盘大小限制已在创建容器时通过 -d root,size= 参数设置
    # 此函数保留用于未来可能的其他存储配置
    :
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
    # IO - 注意：read 和 write 有两个指标（带宽和IOPS），需要分别设置
    # 但 incus 的 limits.read 和 limits.write 只能设置带宽或IOPS其中之一
    # 这里我们优先设置 IOPS 限制
    incus config device set "$name" root limits.read 5000iops || return 1
    incus config device set "$name" root limits.write 5000iops || return 1
    # CPU
    incus config set "$name" limits.cpu.priority 0 || return 1
    incus config set "$name" limits.cpu.allowance 25ms/100ms || return 1
    # Memory
    incus config set "$name" limits.memory.swap true || return 1
    incus config set "$name" limits.memory.swap.priority 1 || return 1
    # Enable docker virtualization
    incus config set "$name" security.nesting true || return 1
}

apply_template() {
    local selected_template="$template"
    [ -z "$selected_template" ] && return 0
    [ "$selected_template" = "none" ] && return 0

    incus config set "$name" user.incus.template "$selected_template" || return 1
    incus config set "$name" boot.autostart true || return 1
    case "$selected_template" in
    web)
        incus config set "$name" security.nesting true || return 1
        incus config set "$name" limits.processes 2048 || return 1
        ;;
    db | database)
        incus config set "$name" limits.cpu.priority 5 || return 1
        incus config set "$name" limits.memory.swap false || return 1
        incus config set "$name" limits.processes 4096 || return 1
        ;;
    dev | development)
        incus config set "$name" security.nesting true || return 1
        incus config set "$name" limits.processes 4096 || return 1
        ;;
    *)
        echo "Unknown template: $selected_template"
        echo "未知模板: $selected_template"
        return 1
        ;;
    esac
}

setup_container() {
    passwd="$(generate_password)"
    if ! incus start "$name"; then
        echo "Container start failed: $name" >&2
        echo "容器启动失败：$name" >&2
        return 1
    fi
    sleep 3
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
    elif echo "$system" | grep -qiE "openwrt"; then
        incus exec "$name" -- opkg update || return 1
    elif echo "$system" | grep -qiE "archlinux"; then
        incus exec "$name" -- pacman -Sy --noconfirm --needed curl dos2unix bash || return 1
    else
        incus exec "$name" -- sudo apt-get update -y || return 1
        incus exec "$name" -- sudo apt-get install curl dos2unix -y --fix-missing || return 1
    fi
}

setup_ssh() {
    if echo "$system" | grep -qiE "alpine|openwrt"; then
        setup_ssh_sh
    else
        setup_ssh_bash
    fi
}

setup_ssh_sh() {
    if [ ! -f /usr/local/bin/ssh_sh.sh ]; then
        curl -fsSLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_sh.sh" -o /usr/local/bin/ssh_sh.sh || return 1
        chmod 755 /usr/local/bin/ssh_sh.sh
        dos2unix /usr/local/bin/ssh_sh.sh
    fi
    cp /usr/local/bin/ssh_sh.sh /root || return 1
    incus file push /root/ssh_sh.sh "$name"/root/ || return 1
    incus exec "$name" -- chmod 755 ssh_sh.sh || return 1
    incus exec "$name" -- ./ssh_sh.sh "$passwd" || return 1
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

wait_for_container_ready_to_shutdown() {
    echo "Waiting for container to complete initialization..."
    echo "等待容器完成初始化配置..."
    local max_wait=18
    local check_interval=6
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if incus exec "$name" -- pgrep -f "apt|yum|pacman|apk|opkg" > /dev/null 2>&1; then
            echo "Container is executing package management operations, continuing to wait..."
            echo "容器正在执行包管理操作，继续等待..."
        elif incus exec "$name" -- pgrep -f "ssh|sshd|config" > /dev/null 2>&1; then
            echo "Container is executing SSH configuration, continuing to wait..."
            echo "容器正在执行SSH配置，继续等待..."
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

safe_shutdown_container() {
    echo "Safely shutting down container..."
    echo "正在安全关闭容器..."
    if ! incus stop "$name" --timeout=30; then
        echo "Error: failed to stop container '$name'." >&2
        return 1
    fi
    local max_shutdown_wait=30
    local waited=0
    while [ $waited -lt $max_shutdown_wait ]; do
        local container_status
        container_status=$(incus info "$name" 2>/dev/null | grep "Status:" | awk '{print $2}')
        if [ "$container_status" = "STOPPED" ]; then
            echo "Container has been safely stopped"
            echo "容器已安全停止"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        echo "Waiting for container to stop... (${waited}/${max_shutdown_wait}s)"
        echo "等待容器停止... (${waited}/${max_shutdown_wait}秒)"
    done
    echo "Error: container stop timed out; aborting configuration." >&2
    echo "错误：容器停止超时，已中止配置。" >&2
    return 1
}

configure_network() {
    incus restart "$name" || return 1
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
    wait_for_container_ready_to_shutdown
    safe_shutdown_container || return 1
    if ((in == out)); then
        speed_limit="$in"
    else
        speed_limit=$(($in > $out ? $in : $out))
    fi
    incus config device override "$name" eth0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit || return 1
    if ! incus config device set "$name" eth0 ipv4.address "$container_ip" 2>/dev/null; then
        if ! incus config device override "$name" eth0 ipv4.address="$container_ip" 2>/dev/null; then
            echo "Error: Failed to apply ipv4.address to device 'eth0' in container '$name'." >&2
            return 1
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
    if echo "$system" | grep -qiE "alpine"; then
        sleep 3
        incus stop "$name" || return 1
        incus start "$name" || return 1
    fi
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
    memory="${3:-256}"
    disk="${4:-2}"
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
    create_container || return 1
    configure_limits || return 1
    apply_template || return 1
    setup_container || return 1
    cleanup_and_finish || return 1
}
if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    main "$@"
fi
