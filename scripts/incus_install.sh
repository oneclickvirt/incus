#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2026.08.30
#
# 支持以下环境变量实现一键非交互式安装 / Supported env vars for non-interactive one-click install:
#
#   noninteractive=true         跳过所有交互提示，使用默认值或其他环境变量值
#                               Skip all interactive prompts; use defaults or other env var values
#
#   INCUS_NONINTERACTIVE=true   兼容旧版非交互变量
#                               Backward-compatible non-interactive flag
#
#   INCUS_STORAGE_PATH=<path>   自定义存储池路径，如 /data/incus-storage（留空则使用系统默认）
#                               Custom storage pool path, e.g. /data/incus-storage (empty = system default)
#
#   INCUS_DISK_SIZE=<GB>        存储池大小（正整数，单位 GB），如 50
#                               Storage pool size in GB (positive integer), e.g. 50
#
#   INCUS_STORAGE_BACKEND=<type> 优先使用指定存储后端，可选 dir/btrfs/lvm/zfs/ceph
#                               Preferred storage backend: dir/btrfs/lvm/zfs/ceph
#
#   WITHOUTCDN=true             跳过 CDN 加速，直连 GitHub
#                               Skip CDN acceleration, connect to GitHub directly
#
# 示例 / Example:
#   export noninteractive=true
#   INCUS_DISK_SIZE=50 bash incus_install.sh
#   INCUS_STORAGE_PATH=/data/incus-storage INCUS_DISK_SIZE=80 bash incus_install.sh

cd /root >/dev/null 2>&1 || exit 1
REGEX=("debian|astra" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon[[:space:]]+linux" "fedora" "arch" "freebsd")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "FreeBSD")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(uname -s)")
SYS="${CMD[0]}"
export DEBIAN_FRONTEND=noninteractive
TRIED_STORAGE_FILE="/usr/local/bin/incus_tried_storage"
INSTALLED_STORAGE_FILE="/usr/local/bin/incus_installed_storage"
STORAGE_POOL_FILE="/usr/local/bin/incus_storage_pool"
MANAGED_STORAGE_POOL="oneclickvirt"
TRIED_STORAGE=()
INSTALLED_STORAGE=()
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")

# Never replace an existing pool. It may own user instances, custom volumes,
# and the root device referenced by the default profile.
storage_pool_exists() {
    local pool_name="${1:-default}"
    incus storage show "$pool_name" >/dev/null 2>&1
}

# `incus query` returns an API envelope on real daemons while test doubles and
# older wrappers may return the metadata object directly.  Normalize both
# forms before inspecting profile/network fields.
api_metadata() {
    jq -c 'if type == "object" and ((.metadata? | type) == "object") then .metadata else . end'
}

valid_storage_pool_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

active_storage_pool() {
    local pool_name=""
    if [ -r "$STORAGE_POOL_FILE" ]; then
        IFS= read -r pool_name <"$STORAGE_POOL_FILE" || true
        if valid_storage_pool_name "$pool_name" && storage_pool_exists "$pool_name"; then
            printf '%s\n' "$pool_name"
            return 0
        fi
    fi
    # Prefer the pool referenced by an existing default profile, including
    # common names such as "local". Do not reinitialize a partially set up host.
    pool_name=$(incus query /1.0/profiles/default 2>/dev/null | api_metadata |
        jq -r '[.devices[]? | select(.type == "disk" and .path == "/") | .pool // empty] | if length == 1 then .[0] else empty end' 2>/dev/null)
    if valid_storage_pool_name "$pool_name" && storage_pool_exists "$pool_name"; then
        printf '%s\n' "$pool_name"
        return 0
    fi
    if storage_pool_exists default; then
        printf '%s\n' default
        return 0
    fi
    local pools
    pools=$(incus storage list --format csv -c n) || return 2
    if [ -n "$pools" ]; then
        if [[ "$pools" != *$'\n'* ]] && valid_storage_pool_name "$pools" && storage_pool_exists "$pools"; then
            printf '%s\n' "$pools"
            return 0
        fi
        _red "Multiple storage pools exist; set STORAGE_POOL_FILE to the pool to reuse" >&2
        return 2
    fi
    return 1
}

record_storage_pool() {
    local pool_name="$1"
    valid_storage_pool_name "$pool_name" || return 1
    printf '%s\n' "$pool_name" >"$STORAGE_POOL_FILE"
}

# A fresh Incus daemon must be initialized before storage pools can be
# created. The automatic initializer may create default; keep that pool and
# use a separate recorded pool for this installer's custom storage path.
initialize_custom_storage_pool() {
    local backend="$1" init_output init_status
    init_output=$(incus admin init --auto 2>&1)
    init_status=$?
    if [ "$init_status" -ne 0 ] && ! grep -Eiq 'already[[:space:]]+(been[[:space:]]+)?initialized|already[[:space:]]+exists|already[[:space:]]+configured' <<<"$init_output"; then
        printf '%s\n' "$init_output" >&2
        _red "Incus 初始化失败，无法创建自定义存储池"
        _red "Incus initialization failed; cannot create the custom storage pool"
        return 1
    fi
    if storage_pool_exists "$MANAGED_STORAGE_POOL"; then
        _yellow "检测到已有 $MANAGED_STORAGE_POOL 存储池，将保留并复用它"
        _yellow "An existing $MANAGED_STORAGE_POOL storage pool was found; preserving and reusing it"
        record_storage_pool "$MANAGED_STORAGE_POOL" || return 1
        return 0
    fi
    if create_storage_pool_with_custom_path "$backend" "$storage_path" "$disk_nums" "$MANAGED_STORAGE_POOL"; then
        record_storage_pool "$MANAGED_STORAGE_POOL" || return 1
        return 0
    fi
    return 1
}

# 检测 sed 是否支持 -E 选项
check_sed_extended_regex() {
    if echo "test" | sed -E 's/test/passed/' >/dev/null 2>&1; then
        SED_EXTENDED="-E"
    else
        SED_EXTENDED="-r"
    fi
}

# 检测 grep 是否支持 -E 选项
check_grep_extended_regex() {
    if echo "test" | grep -E 'test' >/dev/null 2>&1; then
        GREP_EXTENDED="-E"
    else
        GREP_EXTENDED="-e"
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

# 安全的 sed 替换函数，自动选择正确的扩展正则选项
safe_sed() {
    local pattern="$1"
    local file="$2"
    sed $SED_EXTENDED -i "$pattern" "$file"
}

# 安全的 grep 函数，自动选择正确的扩展正则选项
safe_grep() {
    if [ "$GREP_EXTENDED" = "-E" ]; then
        grep -E "$@"
    else
        grep "$@"
    fi
}

init_env() {
    [[ -n $SYS ]] || exit 1
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            SYSTEM="${RELEASE[int]}"
            [[ -n $SYSTEM ]] && break
        fi
    done
    check_grep_extended_regex
    check_grep_perl_regex
    if [ ! -d "/usr/local/bin" ]; then
        mkdir -p /usr/local/bin || return 1
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
    detect_os
}

load_storage_state() {
    TRIED_STORAGE=()
    INSTALLED_STORAGE=()
    if [ -f "$TRIED_STORAGE_FILE" ]; then
        mapfile -t TRIED_STORAGE <"$TRIED_STORAGE_FILE"
    fi
    if [ -f "$INSTALLED_STORAGE_FILE" ]; then
        mapfile -t INSTALLED_STORAGE <"$INSTALLED_STORAGE_FILE"
    fi
}

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }

is_noninteractive() {
    case "${noninteractive:-}" in
        true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    esac
    case "${INCUS_NONINTERACTIVE:-}" in
        true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    esac
    return 1
}

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
        disable)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl disable "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-update >/dev/null 2>&1; then
                if rc-update del "$service_name" default 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v chkconfig >/dev/null 2>&1; then
                if chkconfig "$service_name" off 2>/dev/null; then
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
        stop)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl stop "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                if rc-service "$service_name" stop 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                if service "$service_name" stop 2>/dev/null; then
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
                if systemctl daemon-reload 2>/dev/null; then
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
            PACKAGETYPE_UPDATE="dnf -y makecache"
            PACKAGETYPE_REMOVE="dnf remove -y"
            if [[ "$VERSION" =~ ^7 ]]; then
                PACKAGETYPE="yum"
                PACKAGETYPE_INSTALL="yum install -y"
                PACKAGETYPE_UPDATE="yum -y makecache"
                PACKAGETYPE_REMOVE="yum remove -y"
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
            # `check-update` returns 100 when updates are available, which is
            # a successful state for an installer but would abort this script.
            PACKAGETYPE_UPDATE="dnf -y makecache"
            PACKAGETYPE_REMOVE="dnf remove -y"
        elif command -v yum >/dev/null 2>&1; then
            PACKAGETYPE="yum"
            PACKAGETYPE_INSTALL="yum install -y"
            PACKAGETYPE_UPDATE="yum -y makecache"
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

install_package() {
    package_name=$1
    if command -v "$package_name" >/dev/null 2>&1; then
        _green "$package_name has been installed"
        _green "$package_name 已经安装"
        return 0
    fi
    if $PACKAGETYPE_INSTALL "$package_name"; then
        _green "$package_name has been installed"
        _green "$package_name 已尝试安装"
        return 0
    else
        return 1
    fi
}

install_dependencies() {
    $PACKAGETYPE_UPDATE || {
        _red "Package index update failed; cannot install Incus prerequisites"
        return 1
    }
    local package_name
    for package_name in wget curl sudo dos2unix jq ipcalc unzip bc; do
        install_package "$package_name" || {
            _red "Required package installation failed: $package_name"
            return 1
        }
    done
    install_gpg || {
        _red "Required package installation failed: gpg"
        return 1
    }
}

# Other vendor sysctl files can contain unsupported optional keys. Validate
# the forwarding file we own and the effective value before declaring ready.
apply_forwarding_config() {
    local config_file="$1"
    if sysctl --help 2>&1 | grep -q -- '--system'; then
        if ! sysctl --system >/dev/null 2>&1; then
            sysctl -p "$config_file" >/dev/null 2>&1 || return 1
        fi
    else
        sysctl -p "$config_file" >/dev/null 2>&1 || return 1
    fi
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] || {
        _red "Required IPv4 forwarding is not enabled"
        return 1
    }
}

# uidmap is a Debian package name; other distributions use shadow packages.
install_uidmap() {
    if command -v newuidmap >/dev/null 2>&1 && command -v newgidmap >/dev/null 2>&1; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        install_package uidmap || return 1
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        install_package shadow-utils || return 1
    elif command -v apk >/dev/null 2>&1; then
        install_package shadow-uidmap || install_package shadow || return 1
    elif command -v pacman >/dev/null 2>&1; then
        install_package shadow || return 1
    else
        _red "No supported package manager found for uidmap"
        return 1
    fi
    if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
        _red "newuidmap/newgidmap are still unavailable after package installation"
        return 1
    fi
}

install_gpg() {
    command -v gpg >/dev/null 2>&1 && return 0
    case "$PACKAGETYPE" in
        apt) $PACKAGETYPE_INSTALL gpg || return 1 ;;
        dnf|yum) $PACKAGETYPE_INSTALL gnupg2 || $PACKAGETYPE_INSTALL gnupg || return 1 ;;
        pacman) $PACKAGETYPE_INSTALL gnupg || return 1 ;;
        apk) $PACKAGETYPE_INSTALL gnupg || return 1 ;;
        *) _red "Unable to install gpg for package manager $PACKAGETYPE"; return 1 ;;
    esac
    command -v gpg >/dev/null 2>&1 || {
        _red "gpg is still unavailable after package installation"
        return 1
    }
}

# `lsb_release` is the executable name; package names differ by family.
# Installing the executable name as a package makes Debian/Ubuntu hosts fail
# after Incus itself has already been installed.
install_lsb_release() {
    command -v lsb_release >/dev/null 2>&1 && return 0
    case "${PACKAGETYPE:-}" in
        apt)
            $PACKAGETYPE_INSTALL lsb-release || return 1
            ;;
        dnf|yum)
            $PACKAGETYPE_INSTALL redhat-lsb-core ||
                $PACKAGETYPE_INSTALL lsb-release || return 1
            ;;
        pacman|apk)
            $PACKAGETYPE_INSTALL lsb-release || return 1
            ;;
        *)
            _red "Unable to install lsb_release for package manager ${PACKAGETYPE:-unknown}"
            return 1
            ;;
    esac
    command -v lsb_release >/dev/null 2>&1 || {
        _red "lsb_release is still unavailable after package installation"
        return 1
    }
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

statistics_of_run_times() {
    COUNT=$(curl -4 -ksm1 "https://hits.spiritlhl.net/incus?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/incus?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    if [ "$GREP_PERL_SUPPORT" = true ]; then
        # 如果支持 Perl 正则，使用 grep -oP（更精确）
        TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
        TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
    else
        # 否则使用 BusyBox 兼容的方式
        TODAY=$(echo "$COUNT" | grep -o '"daily":[[:space:]]*[0-9]*' | sed 's/"daily":[[:space:]]*\([0-9]*\)/\1/')
        TOTAL=$(echo "$COUNT" | grep -o '"total":[[:space:]]*[0-9]*' | sed 's/"total":[[:space:]]*\([0-9]*\)/\1/')
    fi
}

rebuild_cloud_init() {
    check_sed_extended_regex
    if [ -f "/etc/cloud/cloud.cfg" ]; then
        chattr -i /etc/cloud/cloud.cfg
        if grep -q "preserve_hostname: true" "/etc/cloud/cloud.cfg"; then
            :
        else
            safe_sed 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
            echo "change preserve_hostname to true"
        fi
        if grep -q "disable_root: false" "/etc/cloud/cloud.cfg"; then
            :
        else
            safe_sed 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
            echo "change disable_root to false"
        fi
        chattr -i /etc/cloud/cloud.cfg
        content=$(cat /etc/cloud/cloud.cfg)
        line_number=$(grep -n "^system_info:" "/etc/cloud/cloud.cfg" | cut -d ':' -f 1)
        if [ -n "$line_number" ]; then
            lines_after_system_info=$(echo "$content" | sed -n "$((line_number + 1)),\$p")
            if [ -n "$lines_after_system_info" ]; then
                updated_content=$(echo "$content" | sed "$((line_number + 1)),\$d")
                echo "$updated_content" >"/etc/cloud/cloud.cfg"
            fi
        fi
        sed -i '/^\s*- set-passwords/s/^/#/' /etc/cloud/cloud.cfg
        chattr +i /etc/cloud/cloud.cfg
    fi
}

install_via_zabbly() {
    echo "使用 Zabbly 仓库安装 incus | Installing incus using Zabbly repository"
    mkdir -p /etc/apt/keyrings/ || return 1
    local key_tmp
    key_tmp=$(mktemp /tmp/zabbly-incus-key.XXXXXX) || return 1
    if ! curl -fsSL https://pkgs.zabbly.com/key.asc -o "$key_tmp" ||
       ! gpg --batch --yes --dearmor -o /etc/apt/keyrings/zabbly.gpg "$key_tmp"; then
        rm -f -- "$key_tmp"
        _red "无法下载或校验 Zabbly 仓库密钥"
        return 1
    fi
    rm -f -- "$key_tmp"
    cat <<EOF >/etc/apt/sources.list.d/zabbly-incus-stable.sources || return 1
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.gpg
EOF
    apt update -y || return 1
    apt install -y incus || return 1
}

ensure_debian_backports_repo() {
    local codename="$1"
    local suite="${codename}-backports"
    local source_file="/etc/apt/sources.list.d/debian-${suite}.sources"

    [ -n "$codename" ] || return 1
    if grep -Rqs "^[[:space:]]*deb .*${suite}" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null ||
        grep -Rqs "^[[:space:]]*Suites:.*${suite}" /etc/apt/sources.list.d 2>/dev/null; then
        return 0
    fi

    cat <<EOF >"${source_file}"
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${suite}
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

install_incus() {
    if ! command -v incus >/dev/null 2>&1; then
        echo "未检测到 incus，开始自动安装... | incus not found, starting installation..."
        if [ -f /etc/alpine-release ]; then
            echo "检测到 Alpine Linux | Detected Alpine Linux"
            echo "取消注释 /etc/apk/repositories 中 edge main 与 edge community 仓库 | Uncommenting edge main and edge community repositories in /etc/apk/repositories"
            sed -i 's/^#\s*\(https:\/\/dl-cdn.alpinelinux.org\/alpine\/edge\/main\)/\1/' /etc/apk/repositories
            sed -i 's/^#\s*\(https:\/\/dl-cdn.alpinelinux.org\/alpine\/edge\/community\)/\1/' /etc/apk/repositories
            apk update || return 1
            echo "安装 incus 和 incus-client | Installing incus and incus-client"
            apk add incus incus-client || return 1
            echo "添加 incus 服务到系统启动，并启动服务 | Adding incus service to system startup and starting service"
            rc-update add incusd || return 1
            rc-service incusd start || return 1
        elif [ -f /etc/debian_version ]; then
            . /etc/os-release
            echo "检测到 $NAME $VERSION_ID | Detected $NAME $VERSION_ID"
            if [[ "$NAME" == "Ubuntu" ]]; then
                if dpkg --compare-versions "$VERSION_ID" ge "24.04"; then
                    echo "使用 Ubuntu 原生 incus 包（24.04 LTS 及以上） | Using Ubuntu native incus package (24.04 LTS and later)"
                    apt update
                    apt install -y incus || install_via_zabbly
                else
                    install_via_zabbly
                fi
            else
                if [[ "$VERSION_CODENAME" == "bookworm" ]]; then
                    echo "使用 Debian 12 (bookworm) 的 backports 包安装 incus | Installing incus from backports for Debian 12 (bookworm)"
                    ensure_debian_backports_repo "$VERSION_CODENAME"
                    apt-get update
                    apt-get install -y -t bookworm-backports incus || install_via_zabbly
                else
                    echo "使用 Debian 原生 incus 包（适用于 testing/unstable） | Installing native incus package for Debian (testing/unstable)"
                    apt update
                    apt install -y incus || install_via_zabbly
                fi
            fi
            service_manager enable incus || return 1
            service_manager start incus || return 1
        elif [ -f /etc/arch-release ]; then
            echo "检测到 Arch Linux | Detected Arch Linux"
            echo "移除 iptables（如果存在）并安装 iptables-nft 与 incus | Removing iptables (if exists) and installing iptables-nft and incus"
            pacman -R --noconfirm iptables >/dev/null 2>&1 || true
            pacman -Syu --noconfirm iptables-nft incus || return 1
            service_manager enable incus || return 1
            service_manager start incus || return 1
        elif [ -f /etc/gentoo-release ]; then
            echo "检测到 Gentoo | Detected Gentoo"
            echo "使用 emerge 安装 incus | Installing incus using emerge"
            emerge -v app-containers/incus || return 1
        elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ] || [ -f /etc/almalinux-release ] || [ -f /etc/rockylinux-release ]; then
            echo "检测到 RPM 系统 | Detected RPM-based system"
            echo "安装 epel-release，并启用 COPR 仓库及 CodeReady Builder (CRB) | Installing epel-release, enabling COPR repository and CodeReady Builder (CRB)"
            dnf -y install epel-release || return 1
            dnf copr enable -y neil/incus || return 1
            dnf config-manager --set-enabled crb || return 1
            echo "安装 incus 与 incus-tools | Installing incus and incus-tools"
            dnf install -y incus incus-tools || return 1
            service_manager enable incus || return 1
            service_manager start incus || return 1
        elif [ -f /etc/void-release ]; then
            echo "检测到 Void Linux | Detected Void Linux"
            echo "使用 xbps 安装 incus 与 incus-client | Installing incus and incus-client using xbps"
            xbps-install -S incus incus-client || return 1
            echo "启用并启动 incus 服务 | Enabling and starting incus service"
            [ -e /var/service/incus ] || ln -s /etc/sv/incus /var/service || return 1
            [ -e /var/service/incus-user ] || ln -s /etc/sv/incus-user /var/service || return 1
            sv up incus || return 1
            sv up incus-user || return 1
        else
            echo "未识别的系统，尝试使用常见包管理器安装 incus | Unrecognized system, trying common package managers to install incus"
            if command -v apt >/dev/null 2>&1; then
                apt update || return 1
                apt install -y incus || return 1
                service_manager enable incus || return 1
                service_manager start incus || return 1
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y incus || return 1
                service_manager enable incus || return 1
                service_manager start incus || return 1
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Syu --noconfirm incus || return 1
                service_manager enable incus || return 1
                service_manager start incus || return 1
            else
                $PACKAGETYPE_INSTALL incus || return 1
                service_manager enable incus || return 1
                service_manager start incus || return 1
            fi
        fi
    else
        echo "incus 已经安装 | incus is already installed"
    fi
    command -v incus >/dev/null 2>&1 || {
        _red "Incus installation did not provide the incus client"
        return 1
    }
    incus --version >/dev/null 2>&1 || return 1
}

setup_firewall() {
    if command -v apt >/dev/null 2>&1; then
        install_package ufw || return 1
        ufw disable || _yellow "ufw could not be disabled; verify forwarding rules manually"
        service_manager stop firewalld 2>/dev/null || true
        service_manager disable firewalld 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        if [ "${SYSTEM:-}" != "Fedora" ]; then
            install_package epel-release || _yellow "Optional EPEL repository unavailable; using configured repositories"
        fi
        install_package firewalld || return 1
        service_manager enable firewalld || return 1
        service_manager start firewalld || return 1
    fi
    # OS detection also uses /etc/os-release; this convenience command is
    # absent from some supported RPM repositories.
    install_lsb_release || _yellow "lsb_release unavailable; using /etc/os-release"
    install_uidmap || return 1
    install_package sipcalc || return 1
}

get_available_space() {
    local available_space
    available_space=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
    echo "$available_space"
}

record_tried_storage() {
    local storage_type="$1"
    if ! is_storage_tried "$storage_type"; then
        echo "$storage_type" >>"$TRIED_STORAGE_FILE"
        TRIED_STORAGE+=("$storage_type")
    fi
}

record_installed_storage() {
    local storage_type="$1"
    if ! is_storage_installed "$storage_type"; then
        echo "$storage_type" >>"$INSTALLED_STORAGE_FILE"
        INSTALLED_STORAGE+=("$storage_type")
    fi
}

is_storage_tried() {
    local storage_type="$1"
    for tried in "${TRIED_STORAGE[@]}"; do
        if [ "$tried" = "$storage_type" ]; then
            return 0
        fi
    done
    return 1
}

is_storage_installed() {
    local storage_type="$1"
    for installed in "${INSTALLED_STORAGE[@]}"; do
        if [ "$installed" = "$storage_type" ]; then
            return 0
        fi
    done
    return 1
}

# 创建稀疏文件
create_sparse_file() {
    local file_path="$1"
    local size_gb="$2"
    if dd if=/dev/zero of="$file_path" bs=1G count=0 seek="${size_gb}" 2>/dev/null; then
        _green "使用 dd 创建稀疏文件成功: $file_path (${size_gb}GB)"
        _green "Successfully created sparse file using dd: $file_path (${size_gb}GB)"
        return 0
    else
        _yellow "dd 创建失败，尝试使用 truncate..."
        _yellow "dd failed, trying truncate..."
        if command -v truncate >/dev/null 2>&1; then
            if truncate -s "${size_gb}G" "$file_path" 2>/dev/null; then
                _green "使用 truncate 创建稀疏文件成功: $file_path (${size_gb}GB)"
                _green "Successfully created sparse file using truncate: $file_path (${size_gb}GB)"
                return 0
            else
                _red "truncate 创建失败"
                _red "truncate failed"
                return 1
            fi
        else
            _red "truncate 命令不可用，无法创建稀疏文件"
            _red "truncate command not available, cannot create sparse file"
            return 1
        fi
    fi
}

create_lvm_restore_service() {
    local loop_file="$1"
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/incus-lvm-losetup.service <<EOF
[Unit]
Description=Setup loop device for Incus LVM storage pool
Before=incus.service
After=local-fs.target
DefaultDependencies=no
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if [ -f "$loop_file" ]; then if ! vgs incus_vg >/dev/null 2>&1; then existing_loop=\$(losetup -j "$loop_file" | cut -d: -f1); if [ -z "\$existing_loop" ]; then loop_dev=\$(losetup -f); losetup "\$loop_dev" "$loop_file"; fi; vgchange -ay incus_vg 2>/dev/null || true; fi; fi'
ExecStop=/bin/bash -c 'vgchange -an incus_vg 2>/dev/null || true; losetup -d \$(losetup -j "$loop_file" | cut -d: -f1) 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF
        service_manager daemon-reload
        service_manager enable incus-lvm-losetup.service
    elif command -v rc-update >/dev/null 2>&1; then
        cat > /etc/init.d/incus-lvm-losetup <<'EOF'
#!/sbin/openrc-run
description="Setup loop device for Incus LVM storage pool"
depend() {
    need localmount
    before incusd
}
start() {
    ebegin "Setting up LVM loop device for Incus"
    LOOP_FILE="LOOP_FILE_PLACEHOLDER"
    if [ ! -f "$LOOP_FILE" ]; then
        eerror "LVM loop file $LOOP_FILE not found"
        eend 1
        return 1
    fi
    if ! vgs incus_vg >/dev/null 2>&1; then
        existing_loop=$(losetup -j "$LOOP_FILE" | cut -d: -f1)
        if [ -z "$existing_loop" ]; then
            loop_dev=$(losetup -f)
            losetup "$loop_dev" "$LOOP_FILE"
        fi
        vgchange -ay incus_vg 2>/dev/null || true
    fi
    eend 0
}
stop() {
    ebegin "Stopping LVM loop device for Incus"
    LOOP_FILE="LOOP_FILE_PLACEHOLDER"
    vgchange -an incus_vg 2>/dev/null || true
    losetup -d $(losetup -j "$LOOP_FILE" | cut -d: -f1) 2>/dev/null || true
    eend 0
}
EOF
        sed -i "s|LOOP_FILE_PLACEHOLDER|$loop_file|g" /etc/init.d/incus-lvm-losetup
        chmod +x /etc/init.d/incus-lvm-losetup
        service_manager enable incus-lvm-losetup
    else
        cat > /usr/local/bin/incus-lvm-restore.sh <<EOF
#!/bin/bash
LOOP_FILE="$loop_file"
if [ ! -f "\$LOOP_FILE" ]; then
    exit 1
fi
if ! vgs incus_vg >/dev/null 2>&1; then
    existing_loop=\$(losetup -j "\$LOOP_FILE" | cut -d: -f1)
    if [ -z "\$existing_loop" ]; then
        loop_dev=\$(losetup -f)
        losetup "\$loop_dev" "\$LOOP_FILE"
    fi
    vgchange -ay incus_vg 2>/dev/null || true
fi
exit 0
EOF
        chmod +x /usr/local/bin/incus-lvm-restore.sh
        if [ -f /etc/rc.local ]; then
            if ! grep -q "incus-lvm-restore.sh" /etc/rc.local; then
                sed -i '/^exit 0/i /usr/local/bin/incus-lvm-restore.sh' /etc/rc.local
            fi
        else
            cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
/usr/local/bin/incus-lvm-restore.sh
exit 0
EOF
            chmod +x /etc/rc.local
        fi
    fi
}

create_zfs_restore_service() {
    local loop_file="$1"
    local zpool_name="$2"
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/incus-zfs-import.service <<EOF
[Unit]
Description=Import ZFS pool for Incus storage
Before=incus.service
After=local-fs.target zfs-import.target
DefaultDependencies=no
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if [ -f "$loop_file" ]; then if ! zpool list "$zpool_name" >/dev/null 2>&1; then zpool import "$zpool_name" 2>/dev/null || zpool import -d \$(dirname "$loop_file") "$zpool_name" 2>/dev/null || true; fi; fi'
ExecStop=/bin/bash -c 'zpool export "$zpool_name" 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF
        service_manager daemon-reload
        service_manager enable incus-zfs-import.service
    elif command -v rc-update >/dev/null 2>&1; then
        cat > /etc/init.d/incus-zfs-import <<'EOF'
#!/sbin/openrc-run
description="Import ZFS pool for Incus storage"
depend() {
    need localmount
    after zfs-import
    before incusd
}
start() {
    ebegin "Importing ZFS pool for Incus"
    LOOP_FILE="LOOP_FILE_PLACEHOLDER"
    ZPOOL_NAME="ZPOOL_NAME_PLACEHOLDER"
    if [ ! -f "$LOOP_FILE" ]; then
        eerror "ZFS loop file $LOOP_FILE not found"
        eend 1
        return 1
    fi
    if ! zpool list "$ZPOOL_NAME" >/dev/null 2>&1; then
        zpool import "$ZPOOL_NAME" 2>/dev/null || zpool import -d $(dirname "$LOOP_FILE") "$ZPOOL_NAME" 2>/dev/null || true
    fi
    eend 0
}
stop() {
    ebegin "Exporting ZFS pool for Incus"
    ZPOOL_NAME="ZPOOL_NAME_PLACEHOLDER"
    zpool export "$ZPOOL_NAME" 2>/dev/null || true
    eend 0
}
EOF
        sed -i "s|LOOP_FILE_PLACEHOLDER|$loop_file|g" /etc/init.d/incus-zfs-import
        sed -i "s|ZPOOL_NAME_PLACEHOLDER|$zpool_name|g" /etc/init.d/incus-zfs-import
        chmod +x /etc/init.d/incus-zfs-import
        service_manager enable incus-zfs-import
    else
        cat > /usr/local/bin/incus-zfs-restore.sh <<EOF
#!/bin/bash
LOOP_FILE="$loop_file"
ZPOOL_NAME="$zpool_name"
if [ ! -f "\$LOOP_FILE" ]; then
    exit 1
fi
if ! zpool list "\$ZPOOL_NAME" >/dev/null 2>&1; then
    zpool import "\$ZPOOL_NAME" 2>/dev/null || zpool import -d \$(dirname "\$LOOP_FILE") "\$ZPOOL_NAME" 2>/dev/null || true
fi
exit 0
EOF
        chmod +x /usr/local/bin/incus-zfs-restore.sh
        if [ -f /etc/rc.local ]; then
            if ! grep -q "incus-zfs-restore.sh" /etc/rc.local; then
                sed -i '/^exit 0/i /usr/local/bin/incus-zfs-restore.sh' /etc/rc.local
            fi
        else
            cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
/usr/local/bin/incus-zfs-restore.sh
exit 0
EOF
            chmod +x /etc/rc.local
        fi
    fi
}

create_storage_pool_with_custom_path() {
    local backend="$1"
    local storage_path="$2"
    local disk_nums="$3"
    local pool_name="${4:-$MANAGED_STORAGE_POOL}"
    local loop_file mount_point temp status
    if ! valid_storage_pool_name "$pool_name"; then
        _red "Invalid managed storage pool name: $pool_name"
        return 1
    fi
    if storage_pool_exists "$pool_name"; then
        _yellow "检测到已有 $pool_name 存储池，将保留并复用它"
        _yellow "An existing $pool_name storage pool was found; preserving and reusing it"
        return 0
    fi
    mkdir -p "$storage_path" || return 1
    if [ "$backend" = "lvm" ]; then
        loop_file="$storage_path/lvm_pool.img"
        _green "创建 LVM 存储池..."
        _green "Creating LVM storage pool..."
        if [ -f "$loop_file" ]; then
            _red "检测到已有 LVM 循环文件，拒绝覆盖：$loop_file"
            _red "Existing LVM loop file found; refusing to overwrite: $loop_file"
            return 1
        fi
        _green "创建稀疏文件：$loop_file (${disk_nums}GB)..."
        if ! create_sparse_file "$loop_file" "$disk_nums"; then
            return 1
        fi
        _green "设置循环设备..."
        loop_dev=$(losetup -f) || return 1
        losetup "$loop_dev" "$loop_file" || return 1
        _green "创建 LVM 物理卷和卷组..."
        pvcreate "$loop_dev" >/dev/null 2>&1 || return 1
        vgcreate incus_vg "$loop_dev" >/dev/null 2>&1 || return 1
        printf '%s\n' "$loop_file" > "$storage_path/lvm_loop_file.txt" || return 1
        create_lvm_restore_service "$loop_file" || return 1
        temp=$(incus storage create "$pool_name" lvm source=incus_vg 2>&1)
        status=$?
    elif [ "$backend" = "btrfs" ]; then
        loop_file="$storage_path/btrfs_pool.img"
        mount_point="$storage_path/btrfs_mount"
        _green "创建 btrfs 存储池..."
        _green "Creating btrfs storage pool..."
        if mountpoint -q "$mount_point" 2>/dev/null; then
            _red "检测到已挂载的 btrfs 路径，拒绝卸载：$mount_point"
            _red "Existing btrfs mount found; refusing to unmount: $mount_point"
            return 1
        fi
        if [ -f "$loop_file" ]; then
            _red "检测到已有 btrfs 循环文件，拒绝覆盖：$loop_file"
            _red "Existing btrfs loop file found; refusing to overwrite: $loop_file"
            return 1
        fi
        _green "创建稀疏文件：$loop_file (${disk_nums}GB)..."
        if ! create_sparse_file "$loop_file" "$disk_nums"; then
            return 1
        fi
        _green "格式化为 btrfs..."
        mkfs.btrfs -f "$loop_file" >/dev/null 2>&1 || return 1
        mkdir -p "$mount_point" || return 1
        _green "挂载到 $mount_point..."
        if ! mount -o loop "$loop_file" "$mount_point"; then
            _red "挂载失败！"
            _red "Mount failed!"
            return 1
        fi
        if ! mountpoint -q "$mount_point"; then
            _red "挂载失败！"
            _red "Mount failed!"
            return 1
        fi
        if ! grep -q "$loop_file" /etc/fstab 2>/dev/null; then
            if ! printf '%s\n' "$loop_file $mount_point btrfs loop 0 0" >> /etc/fstab; then
                _red "无法写入 /etc/fstab，取消 btrfs 存储池创建"
                umount "$mount_point" 2>/dev/null || true
                rm -f -- "$loop_file"
                return 1
            fi
            _green "已添加到 /etc/fstab 实现开机自动挂载"
            _green "Added to /etc/fstab for automatic mounting on boot"
        fi
        chmod 711 "$mount_point" || return 1
        temp=$(incus storage create "$pool_name" btrfs source="$mount_point" 2>&1)
        status=$?
    elif [ "$backend" = "zfs" ]; then
        loop_file="$storage_path/zfs_pool.img"
        local zpool_name="incus_zfs_pool"
        _green "创建 ZFS 存储池..."
        _green "Creating ZFS storage pool..."
        if zpool list "$zpool_name" >/dev/null 2>&1; then
            _red "检测到已有 ZFS 存储池，拒绝销毁：$zpool_name"
            _red "Existing ZFS pool found; refusing to destroy: $zpool_name"
            return 1
        fi
        if [ -f "$loop_file" ]; then
            _red "检测到已有 ZFS 循环文件，拒绝覆盖：$loop_file"
            _red "Existing ZFS loop file found; refusing to overwrite: $loop_file"
            return 1
        fi
        _green "创建稀疏文件：$loop_file (${disk_nums}GB)..."
        if ! create_sparse_file "$loop_file" "$disk_nums"; then
            return 1
        fi
        _green "创建 ZFS pool..."
        zpool create -f "$zpool_name" "$loop_file" >/dev/null 2>&1 || return 1
        if ! zpool list "$zpool_name" >/dev/null 2>&1; then
            _red "ZFS pool 创建失败！"
            _red "ZFS pool creation failed!"
            return 1
        fi
        printf '%s\n' "$loop_file" > "$storage_path/zfs_loop_file.txt" || return 1
        printf '%s\n' "$zpool_name" > "$storage_path/zfs_pool_name.txt" || return 1
        create_zfs_restore_service "$loop_file" "$zpool_name" || return 1
        temp=$(incus storage create "$pool_name" zfs source="$zpool_name" 2>&1)
        status=$?
    elif [ "$backend" = "dir" ]; then
        temp=$(incus storage create "$pool_name" dir source="$storage_path" 2>&1)
        status=$?
    else
        _red "不支持的存储后端：$backend"
        _red "Unsupported storage backend: $backend"
        return 1
    fi
    echo "$temp"
    return $status
}

init_storage_backend() {
    local backend="$1"
    local existing_pool
    if existing_pool=$(active_storage_pool); then
        _yellow "检测到现有 $existing_pool 存储池，将保留并复用它"
        _yellow "An existing $existing_pool storage pool was found; preserving and reusing it"
        record_storage_pool "$existing_pool" || return 1
        return 0
    fi
    if is_storage_tried "$backend"; then
        _yellow "已经尝试过 ${backend}，跳过"
        _yellow "Already tried $backend, skipping"
        return 1
    fi
    if [ "$backend" = "dir" ]; then
        _green "使用默认dir类型无限定存储池大小"
        _green "Using default dir type with unlimited storage pool size"
        echo "dir" >/usr/local/bin/incus_storage_type
        if [ -n "$storage_path" ]; then
            mkdir -p "$storage_path" || return 1
            if initialize_custom_storage_pool "$backend"; then
                record_tried_storage "$backend"
                return 0
            fi
            record_tried_storage "$backend"
            return 1
        else
            # 默认挂载到 /var/lib/incus/storage-pools/default
            if incus admin init --storage-backend "$backend" --auto && storage_pool_exists default; then
                record_storage_pool default || return 1
                record_tried_storage "$backend"
                return 0
            fi
            record_tried_storage "$backend"
            return 1
        fi
    fi
    _green "尝试使用 $backend 类型，存储池大小为 $disk_nums"
    _green "Trying to use $backend type with storage pool size $disk_nums"
    local need_reboot=false
    if [ "$backend" = "btrfs" ] && ! is_storage_installed "btrfs" && ! command -v btrfs >/dev/null; then
        _yellow "正在安装 btrfs-progs..."
        _yellow "Installing btrfs-progs..."
        $PACKAGETYPE_INSTALL btrfs-progs || {
            _red "btrfs-progs 安装失败，停止存储初始化"
            return 1
        }
        record_installed_storage "btrfs"
        modprobe btrfs || true
        _green "无法加载btrfs模块。请重启本机再次执行本脚本以加载btrfs内核。"
        _green "btrfs module could not be loaded. Please reboot the machine and execute this script again."
        echo "$backend" >/usr/local/bin/incus_reboot
        need_reboot=true
    elif [ "$backend" = "lvm" ] && ! is_storage_installed "lvm" && ! command -v lvm >/dev/null; then
        _yellow "正在安装 lvm2..."
        _yellow "Installing lvm2..."
        $PACKAGETYPE_INSTALL lvm2 || {
            _red "lvm2 安装失败，停止存储初始化"
            return 1
        }
        record_installed_storage "lvm"
        modprobe dm-mod || true
        _green "无法加载LVM模块。请重启本机再次执行本脚本以加载LVM内核。"
        _green "LVM module could not be loaded. Please reboot the machine and execute this script again."
        echo "$backend" >/usr/local/bin/incus_reboot
        need_reboot=true
    elif [ "$backend" = "zfs" ] && ! is_storage_installed "zfs" && ! command -v zfs >/dev/null; then
        _yellow "正在安装 zfsutils-linux..."
        _yellow "Installing zfsutils-linux..."
        $PACKAGETYPE_INSTALL zfsutils-linux || {
            _red "zfsutils-linux 安装失败，停止存储初始化"
            return 1
        }
        record_installed_storage "zfs"
        modprobe zfs || true
        _green "无法加载ZFS模块。请重启本机再次执行本脚本以加载ZFS内核。"
        _green "ZFS module could not be loaded. Please reboot the machine and execute this script again."
        echo "$backend" >/usr/local/bin/incus_reboot
        need_reboot=true
    elif [ "$backend" = "ceph" ] && ! is_storage_installed "ceph" && ! command -v ceph >/dev/null; then
        _yellow "正在安装 ceph-common..."
        _yellow "Installing ceph-common..."
        $PACKAGETYPE_INSTALL ceph-common || {
            _red "ceph-common 安装失败，停止存储初始化"
            return 1
        }
        record_installed_storage "ceph"
    fi
    if [ "$backend" = "btrfs" ] && is_storage_installed "btrfs" && ! grep -q btrfs /proc/filesystems; then
        modprobe btrfs || true
    elif [ "$backend" = "lvm" ] && is_storage_installed "lvm" && ! grep -q dm-mod /proc/modules; then
        modprobe dm-mod || true
    elif [ "$backend" = "zfs" ] && is_storage_installed "zfs" && ! grep -q zfs /proc/filesystems; then
        modprobe zfs || true
    fi
    if [ "$need_reboot" = true ]; then
        # A missing optional kernel module must not abort the whole installer.
        # Leave the marker for a later retry and let setup_storage try the next
        # backend (ultimately dir) so IPv4 container creation remains usable.
        return 1
    fi
    local temp
    if existing_pool=$(active_storage_pool); then
        _yellow "检测到现有 $existing_pool 存储池，将保留并复用它"
        _yellow "An existing $existing_pool storage pool was found; preserving and reusing it"
        record_storage_pool "$existing_pool" || return 1
        echo "Existing $existing_pool storage pool preserved"
        return 0
    fi

    if [ -n "$storage_path" ]; then
        _yellow "当前存储池列表："
        _yellow "Current storage pools:"
        incus storage list 2>/dev/null || true
        if initialize_custom_storage_pool "$backend"; then
            temp="Storage pool created successfully"
            status=0
        else
            temp="Failed to create storage pool with custom path"
            status=1
        fi
    else
        temp=$(incus admin init --storage-backend "$backend" --storage-create-loop "$disk_nums" --storage-pool default --auto 2>&1)
        status=$?
        if [ "$status" -eq 0 ] && storage_pool_exists default; then
            record_storage_pool default || return 1
        fi
    fi
    _green "Init storage:"
    echo "$temp"
    if echo "$temp" | grep -q "incus.migrate" && [ $status -ne 0 ]; then
        incus.migrate
        temp=$(incus admin init --auto 2>&1)
        if [ -n "$storage_path" ]; then
            _yellow "当前存储池列表："
            _yellow "Current storage pools:"
            incus storage list 2>/dev/null || true
            if initialize_custom_storage_pool "$backend"; then
                temp="Storage pool created successfully after migration"
                status=0
            else
                temp="Failed to create storage pool with custom path after migration"
                status=1
            fi
        else
            temp=$(incus admin init --storage-backend "$backend" --storage-create-loop "$disk_nums" --storage-pool default --auto 2>&1)
            status=$?
            if [ "$status" -eq 0 ] && storage_pool_exists default; then
                record_storage_pool default || return 1
            fi
        fi
        echo "$temp"
    fi
    record_tried_storage "$backend"
    if [ $status -eq 0 ]; then
        _green "使用 $backend 初始化成功"
        _green "Successfully initialized using $backend"
        echo "$backend" >/usr/local/bin/incus_storage_type
        return 0
    else
        _yellow "使用 $backend 初始化失败，尝试下一个选项"
        _yellow "Initialization with $backend failed, trying next option"
        return 1
    fi
}

setup_storage() {
    local existing_pool pool_status
    if existing_pool=$(active_storage_pool); then
        _green "检测到现有 $existing_pool 存储池，跳过后端重新初始化"
        _green "An existing $existing_pool storage pool was found; skipping backend reinitialization"
        record_storage_pool "$existing_pool" || return 1
        return 0
    else
        pool_status=$?
        [ "$pool_status" -eq 1 ] || return "$pool_status"
    fi
    if [ -f "/usr/local/bin/incus_storage_type" ]; then
        current_backend=$(cat /usr/local/bin/incus_storage_type)
        if [ "$current_backend" = "btrfs" ] && [ -f "/etc/fstab" ]; then
            local storage_recovery_failed=false
            while read -r line; do
                mount_point=$(echo "$line" | awk '{print $2}')
                if [ -n "$mount_point" ] && [ -d "$mount_point" ]; then
                    if ! mountpoint -q "$mount_point" 2>/dev/null; then
                        _yellow "检测到未挂载的 btrfs 存储池，正在重新挂载..."
                        _yellow "Detected unmounted btrfs storage pool, remounting..."
                        if ! mount "$mount_point" 2>/dev/null || ! mountpoint -q "$mount_point" 2>/dev/null; then
                            storage_recovery_failed=true
                        fi
                    fi
                fi
            done < <(grep "btrfs_pool.img" /etc/fstab 2>/dev/null || true)
            if [ "$storage_recovery_failed" = true ]; then
                _red "无法恢复 Incus btrfs 存储挂载，停止以保护现有数据"
                return 1
            fi
        elif [ "$current_backend" = "lvm" ]; then
            if ! vgs incus_vg >/dev/null 2>&1; then
                local storage_recovery_failed=false
                for storage_dir in /data/incus-storage /var/lib/incus-storage /root/incus-storage; do
                    lvm_info="$storage_dir/lvm_loop_file.txt"
                    if [ -f "$lvm_info" ]; then
                        loop_file=$(cat "$lvm_info")
                        if [ -f "$loop_file" ]; then
                            _yellow "检测到 LVM 存储池未激活，正在恢复..."
                            _yellow "Detected inactive LVM storage pool, recovering..."
                            loop_dev=$(losetup -f)
                            if ! losetup "$loop_dev" "$loop_file" 2>/dev/null || ! vgchange -ay incus_vg 2>/dev/null; then
                                storage_recovery_failed=true
                            fi
                            break
                        fi
                    fi
                done
                if [ "$storage_recovery_failed" = true ]; then
                    _red "无法恢复 Incus LVM 存储，停止以保护现有数据"
                    return 1
                fi
            fi
        elif [ "$current_backend" = "zfs" ]; then
            local storage_recovery_failed=false
            for storage_dir in /data/incus-storage /var/lib/incus-storage /root/incus-storage; do
                zfs_pool_info="$storage_dir/zfs_pool_name.txt"
                zfs_loop_info="$storage_dir/zfs_loop_file.txt"
                if [ -f "$zfs_pool_info" ] && [ -f "$zfs_loop_info" ]; then
                    zpool_name=$(cat "$zfs_pool_info")
                    loop_file=$(cat "$zfs_loop_info")
                    if [ -n "$zpool_name" ] && [ -f "$loop_file" ]; then
                        if ! zpool list "$zpool_name" >/dev/null 2>&1; then
                            _yellow "检测到 ZFS 存储池未导入，正在恢复..."
                            _yellow "Detected ZFS storage pool not imported, recovering..."
                            if ! zpool import "$zpool_name" 2>/dev/null && ! zpool import -d "$(dirname "$loop_file")" "$zpool_name" 2>/dev/null; then
                                storage_recovery_failed=true
                            fi
                        fi
                        break
                    fi
                fi
            done
            if [ "$storage_recovery_failed" = true ]; then
                _red "无法恢复 Incus ZFS 存储，停止以保护现有数据"
                return 1
            fi
        fi
    fi
    
    if [ -f "/usr/local/bin/incus_reboot" ]; then
        REBOOT_BACKEND=$(cat /usr/local/bin/incus_reboot)
        _green "检测到系统重启，尝试继续使用 $REBOOT_BACKEND"
        _green "System reboot detected, trying to continue with $REBOOT_BACKEND"
        rm -f /usr/local/bin/incus_reboot
        if [ "$REBOOT_BACKEND" = "btrfs" ]; then
            modprobe btrfs || true
        elif [ "$REBOOT_BACKEND" = "lvm" ]; then
            modprobe dm-mod || true
        elif [ "$REBOOT_BACKEND" = "zfs" ]; then
            modprobe zfs || true
        fi
        if init_storage_backend "$REBOOT_BACKEND"; then
            return 0
        fi
    fi
    local BACKENDS=()
    if [ -n "${INCUS_STORAGE_BACKEND:-}" ]; then
        case "${INCUS_STORAGE_BACKEND}" in
            dir|btrfs|lvm|zfs|ceph)
                BACKENDS=("${INCUS_STORAGE_BACKEND}")
                [ "${INCUS_STORAGE_BACKEND}" = "dir" ] || BACKENDS+=("dir")
                ;;
            *)
                _yellow "Unsupported INCUS_STORAGE_BACKEND=${INCUS_STORAGE_BACKEND}, using automatic backend selection"
                _yellow "不支持的 INCUS_STORAGE_BACKEND=${INCUS_STORAGE_BACKEND}，改用自动存储后端选择"
                ;;
        esac
    fi
    if [ "${#BACKENDS[@]}" -eq 0 ] && command -v apt >/dev/null; then
        BACKENDS=("btrfs" "lvm" "zfs" "ceph" "dir")
    elif [ "${#BACKENDS[@]}" -eq 0 ]; then
        BACKENDS=("lvm" "zfs" "ceph" "dir")
    fi
    for backend in "${BACKENDS[@]}"; do
        if init_storage_backend "$backend"; then
            return 0
        fi
    done
    _yellow "所有存储类型尝试失败，使用 dir 作为备选"
    _yellow "All storage types failed, using dir as fallback"
    echo "dir" >/usr/local/bin/incus_storage_type
    if [ -n "$storage_path" ]; then
        mkdir -p "$storage_path" || return 1
        initialize_custom_storage_pool dir
    else
        if incus admin init --storage-backend dir --auto && storage_pool_exists default; then
            record_storage_pool default || return 1
            return 0
        fi
        return 1
    fi
}

get_user_inputs() {
    # ---- storage_path ----
    # 优先使用 INCUS_STORAGE_PATH 环境变量（即使值为空也视为"已指定，不使用自定义路径"）
    if [ "${INCUS_STORAGE_PATH+x}" = "x" ]; then
        storage_path="${INCUS_STORAGE_PATH}"
        if [ -n "$storage_path" ]; then
            if [ ! -d "$storage_path" ]; then
                mkdir -p "$storage_path" 2>/dev/null || {
                    _yellow "Warning: failed to create INCUS_STORAGE_PATH=$storage_path, falling back to system default."
                    storage_path=""
                }
            fi
            [ -n "$storage_path" ] && _green "使用环境变量指定的存储路径 / Using storage path from env: $storage_path"
        fi
    elif is_noninteractive; then
        storage_path=""
    else
        while true; do
            _green "Do you want to specify a custom path for the storage pool? (y/n) [n]:"
            reading "是否需要指定存储池的自定义路径？(y/n) [n]：" use_custom_path
            use_custom_path=${use_custom_path:-n}
            if [[ "$use_custom_path" =~ ^[yYnN]$ ]]; then
                break
            else
                _yellow "Please enter y or n."
                _yellow "请输入 y 或 n。"
            fi
        done
        if [[ "$use_custom_path" =~ ^[yY]$ ]]; then
            while true; do
                _green "Please enter the custom storage path (e.g., /data/incus-storage):"
                reading "请输入自定义存储路径 (例如：/data/incus-storage)：" storage_path
                if [[ -n "$storage_path" && "$storage_path" =~ ^/.+ ]]; then
                    if [ ! -d "$storage_path" ]; then
                        mkdir -p "$storage_path" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            _green "Created directory: $storage_path"
                            _green "已创建目录：$storage_path"
                            break
                        else
                            _yellow "Failed to create directory. Please check permissions or try another path."
                            _yellow "创建目录失败，请检查权限或尝试其他路径。"
                        fi
                    else
                        break
                    fi
                else
                    _yellow "Please enter a valid absolute path starting with /."
                    _yellow "请输入以 / 开头的有效绝对路径。"
                fi
            done
        else
            storage_path=""
        fi
    fi

    # ---- disk_nums ----
    # 优先使用 INCUS_DISK_SIZE 环境变量
    if [[ "${INCUS_DISK_SIZE:-}" =~ ^[1-9][0-9]*$ ]]; then
        disk_nums="$INCUS_DISK_SIZE"
        _green "使用环境变量指定的存储池大小 / Using disk size from env: ${disk_nums}GB"
    elif is_noninteractive; then
        available_space=$(get_available_space)
        disk_nums=$((available_space - 1))
        if [ "$disk_nums" -lt 1 ]; then
            disk_nums=1
        fi
        _green "非交互模式使用默认存储池大小 / Non-interactive disk size: ${disk_nums}GB"
    else
        while true; do
            _green "How large a storage pool does the host need to open? (The storage pool is the size of the sum of the ct's hard disk, it is recommended that the storage pool reaches 95% of the space of the host's hard disk, note that it is in GB, enter 10 if you need 10G storage pool):"
            reading "宿主机需要开设多大的存储池？(存储池就是容器硬盘之和的大小，推荐存储池达到宿主机硬盘的95%空间，注意是GB为单位，需要10G存储池则输入10)：" disk_nums
            if [[ "$disk_nums" =~ ^[1-9][0-9]*$ ]]; then
                break
            else
                _yellow "Invalid input, please enter a positive integer."
                _yellow "输入无效，请输入一个正整数。"
            fi
        done
    fi
}

download_preconfigured_files() {
    files=(
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_sh.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/image_lookup.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/buildct.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/buildvm.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/instance_ops.sh"
        "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/macvlan.sh"
    )
    for file in "${files[@]}"; do
        filename=$(basename "$file")
        rm -f "$filename"
        attempt=1
        max_attempts=5
        success=0
        while (( attempt <= max_attempts )); do
            echo "Downloading $filename (attempt $attempt)..."
            if curl -fsSLk "${cdn_success_url}${file}" -o "$filename"; then
                chmod 755 "$filename" || return 1
                dos2unix "$filename" || return 1
                success=1
                break
            else
                sleep_time=$((2 ** (attempt - 1))) # 1, 2, 4, 8, 16
                echo "Download failed. Retrying in $sleep_time seconds..."
                sleep "$sleep_time"
                ((attempt++))
            fi
        done
        if (( success == 0 )); then
            echo "Failed to download $filename after $max_attempts attempts."
            return 1
        fi
    done
}

# Storage initialization can be skipped on a reused host; profile and network
# initialization must still run. Only add missing devices/settings and preserve
# existing pools, custom NICs, addresses and explicit IPv6 disablement.
ensure_runtime_network() {
    local pool profiles profile roots root_pool nics nic network bridge="incusbr0" networks config value
    command -v jq >/dev/null 2>&1 || { _red "jq is required to verify initialization"; return 1; }
    incus info >/dev/null 2>&1 || { _red "Incus daemon is unavailable"; return 1; }
    pool=$(active_storage_pool) || { _red "No unambiguous usable storage pool"; return 1; }
    profiles=$(incus profile list --format csv -c n) || return 1
    if ! grep -Fxq default <<< "$profiles"; then
        incus profile create default || return 1
    fi
    profile=$(incus query /1.0/profiles/default | api_metadata) || return 1
    roots=$(jq -er '[.devices // {} | to_entries[] | select(.value.type == "disk" and .value.path == "/")] | length' <<< "$profile") || return 1
    if [ "$roots" -eq 0 ]; then
        if jq -e '.devices.root != null' <<< "$profile" >/dev/null; then
            _red "default profile device root is already used; leaving it unchanged"
            return 1
        fi
        incus profile device add default root disk path=/ pool="$pool" || return 1
    elif [ "$roots" -eq 1 ]; then
        root_pool=$(jq -r '.devices[] | select(.type == "disk" and .path == "/") | .pool // empty' <<< "$profile")
        if [ -z "$root_pool" ] || ! storage_pool_exists "$root_pool"; then
            _red "default profile root refers to an unavailable pool; leaving it unchanged"
            return 1
        fi
    else
        _red "default profile has multiple root disks; leaving it unchanged"
        return 1
    fi

    nics=$(jq -er '[.devices // {} | to_entries[] | select(.value.type == "nic")] | length' <<< "$profile") || return 1
    if [ "$nics" -gt 0 ]; then
        # Custom NIC layouts are user configuration. Validate their referenced
        # resources without replacing them with the installer's default bridge.
        while IFS= read -r nic; do
            network=$(jq -r '.network // empty' <<< "$nic")
            if [ "$network" = "$bridge" ]; then
                continue # A missing installer bridge is repaired below.
            elif [ "$network" = "none" ]; then
                # `none` is a valid explicit Incus profile choice; preserve
                # it without looking for a network object of that name.
                continue
            elif [ -n "$network" ]; then
                incus network show "$network" >/dev/null || return 1
            else
                network=$(jq -r '.parent // empty' <<< "$nic")
                [ -z "$network" ] || [ "$network" = "$bridge" ] || ip link show dev "$network" >/dev/null || return 1
            fi
        done < <(jq -c '.devices[] | select(.type == "nic")' <<< "$profile")
        if ! jq -e --arg bridge "$bridge" '.devices[] | select(.type == "nic" and (.network == $bridge or .parent == $bridge))' <<< "$profile" >/dev/null; then
            _yellow "Preserving the custom default-profile network; ensuring the installer bridge separately"
        fi
    elif jq -e '.devices.eth0 != null' <<< "$profile" >/dev/null; then
        _red "default profile device eth0 is already used; leaving it unchanged"
        return 1
    fi

    networks=$(incus network list --format csv -c n) || return 1
    if ! grep -Fxq "$bridge" <<< "$networks"; then
        if ip link show dev "$bridge" >/dev/null 2>&1; then
            _red "$bridge already exists outside Incus; refusing to replace it"
            return 1
        fi
        # IPv4 is required for the default NAT setup. IPv6 is optional.
        incus network create "$bridge" ipv4.address=auto ipv4.nat=true ipv4.dhcp=true ipv6.address=none || return 1
        incus network set "$bridge" ipv6.address auto || _yellow "IPv6 unavailable; retaining IPv4 networking"
    fi
    config=$(incus query "/1.0/networks/$bridge" | api_metadata) || return 1
    jq -e '.type == "bridge" and .managed == true' <<< "$config" >/dev/null || {
        _red "$bridge is not a managed bridge"; return 1;
    }
    for value in ipv4.address ipv4.dhcp ipv4.nat; do
        network=$(jq -r --arg key "$value" '.config[$key] // empty' <<< "$config") || return 1
        if [ -z "$network" ]; then
            if [ "$value" = ipv4.address ]; then
                incus network set "$bridge" "$value" auto || return 1
            else
                incus network set "$bridge" "$value" true || return 1
            fi
        elif { [ "$value" = ipv4.address ] && [ "$network" = none ]; } ||
             { [ "$value" = ipv4.dhcp ] && [ "$network" = false ]; }; then
            _red "$bridge explicitly disables $value; default IPv4 NAT is unavailable (setting preserved)"
            return 1
        fi
    done
    if [ "$nics" -eq 0 ]; then
        incus profile device add default eth0 nic network="$bridge" name=eth0 || return 1
    fi
    # Incus may report the managed network ready just before the bridge is
    # visible in the host link table. Give udev/netlink a short bounded window
    # before declaring initialization failed.
    local link_attempt=0
    while ! ip link show dev "$bridge" >/dev/null 2>&1; do
        link_attempt=$((link_attempt + 1))
        if [ "$link_attempt" -ge 10 ]; then
            _red "$bridge has no host interface"
            return 1
        fi
        sleep 1
    done
    _green "Incus storage, default profile and $bridge are ready"
}

configure_incus_settings() {
    ensure_runtime_network || return 1
    # Set managed DNS only when the bridge has no explicit choice. Preserve
    # administrators' `none`, `dynamic`, or custom DNS configuration.
    local network_config dns_mode
    network_config=$(incus query "/1.0/networks/incusbr0" | api_metadata) || return 1
    dns_mode=$(jq -r '.config["dns.mode"] // empty' <<< "$network_config") || return 1
    if [ -z "$dns_mode" ]; then
        incus network set incusbr0 dns.mode managed || return 1
    fi
    incus config set images.auto_update_interval 0 || return 1
    incus remote add opsmaru https://images.opsmaru.dev/spaces/43ad54472be82d7236eea3d1 --public --protocol simplestreams >/dev/null 2>&1 ||
        _yellow "Optional image remote opsmaru already exists or is unavailable"
}

optimize_system() {
    command -v sysctl >/dev/null 2>&1 || {
        _red "sysctl is required to enable IPv4 forwarding"
        return 1
    }
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
    SYSCTL_CONF="/etc/sysctl.conf"
    SYSCTL_D_CONF="/etc/sysctl.d/99-custom.conf"
    if [ -f "$SYSCTL_CONF" ]; then
        if grep -q "^net.ipv4.ip_forward=1" "$SYSCTL_CONF"; then
            sed -i 's/^#\?net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' "$SYSCTL_CONF"
        else
            echo "net.ipv4.ip_forward=1" >>"$SYSCTL_CONF"
        fi
    fi
    mkdir -p /etc/sysctl.d || return 1
    if ! grep -q "^net.ipv4.ip_forward=1" "$SYSCTL_D_CONF" 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >>"$SYSCTL_D_CONF" || return 1
    fi
    apply_forwarding_config "$SYSCTL_D_CONF" || return 1
    if [ -f "/etc/security/limits.conf" ]; then
        grep -Fq "*          hard    nproc       unlimited" /etc/security/limits.conf || \
            echo '*          hard    nproc       unlimited' | sudo tee -a /etc/security/limits.conf
        grep -Fq "*          soft    nproc       unlimited" /etc/security/limits.conf || \
            echo '*          soft    nproc       unlimited' | sudo tee -a /etc/security/limits.conf
    fi
    if [ -f "/etc/systemd/logind.conf" ]; then
        grep -q "^UserTasksMax=infinity" /etc/systemd/logind.conf || \
            echo 'UserTasksMax=infinity' | sudo tee -a /etc/systemd/logind.conf
    fi
    if [ -f "/etc/gai.conf" ]; then
        sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf
        service_manager restart networking 2>/dev/null || true
    fi
    return 0
}

install_dns_checker() {
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        _yellow "No systemd installation detected; skipping optional DNS checker"
        return 0
    fi
    if [ ! -f /usr/local/bin/check-dns.sh ]; then
        wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/check-dns.sh" -O /usr/local/bin/check-dns.sh || return 1
        chmod +x /usr/local/bin/check-dns.sh || return 1
    else
        echo "Script already exists. Skipping installation."
    fi
    if [ ! -f /etc/systemd/system/check-dns.service ]; then
        wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/check-dns.service" -O /etc/systemd/system/check-dns.service || return 1
        chmod +x /etc/systemd/system/check-dns.service || return 1
        service_manager daemon-reload || return 1
        service_manager enable check-dns.service || return 1
        service_manager start check-dns.service || return 1
    else
        echo "Service already exists. Skipping installation."
    fi
}

ensure_nftables() {
    if command -v nft >/dev/null 2>&1; then
        return 0
    fi
    $PACKAGETYPE_INSTALL nftables >/dev/null 2>&1 || true
    if command -v nft >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
            systemctl start nftables 2>/dev/null || true
        fi
        return 0
    fi
    return 1
}

ensure_iptables_persistent() {
    if command -v apt >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || return 1
    fi
    return 0
}

save_firewall_rules() {
    if command -v nft >/dev/null 2>&1; then
        # Only save our own custom tables, NOT incusd's managed 'incus' table.
        # Saving 'nft list ruleset' would include incusd's transient tables which
        # reference interfaces (incusbr0) that don't exist at nftables.service
        # start time, causing firewall/SSH breakage on reboot.
        local nft_file=/etc/nftables.d/oneclickvirt-incus.nft
        local tables rules block_rules="" temporary
        tables=$(nft list tables) || return 1
        rules=$(nft list table inet incus_masq) || return 1
        if grep -Fxq 'table inet incus_block' <<<"$tables"; then
            block_rules=$(nft list table inet incus_block) || return 1
        fi
        mkdir -p /etc/nftables.d || return 1
        temporary=$(mktemp /etc/nftables.d/.oneclickvirt-incus.XXXXXX) || return 1
        # Prepare the full snapshot before replacing our file. A read failure
        # must not truncate the last working persistent rules.
        local saved_rules=('#!/usr/sbin/nft -f' 'add table inet incus_masq' 'flush table inet incus_masq' "$rules")
        if [ -n "$block_rules" ]; then
            saved_rules+=('add table inet incus_block' 'flush table inet incus_block' "$block_rules")
        fi
        if ! printf '%s\n' "${saved_rules[@]}" >"$temporary" || ! chmod 644 "$temporary" || ! mv -f "$temporary" "$nft_file"; then
            rm -f -- "$temporary"
            return 1
        fi
        # Keep host rules and other runtimes' includes in the main config.
        if ! grep -Eq '^[[:space:]]*include[[:space:]]+"/etc/nftables.d/(oneclickvirt-incus|\*)\.nft"' /etc/nftables.conf 2>/dev/null; then
            printf '\n%s\n' 'include "/etc/nftables.d/oneclickvirt-incus.nft"' >>/etc/nftables.conf || return 1
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
        fi
    else
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        fi
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
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
    nft_rule_exists "$family" "$table" "$chain" "$pattern" || nft add rule "$family" "$table" "$chain" "$@" 2>/dev/null || return 1
}

add_iptables_masq_once() {
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null || return 1
}

setup_iptables() {
    if command -v ufw >/dev/null 2>&1; then
        ufw allow in on incusbr0
        ufw route allow in on incusbr0
        ufw route allow out on incusbr0
    fi
    if ensure_nftables; then
        # Use nftables for MASQUERADE (handles both IPv4 and IPv6)
        nft add table inet incus_masq 2>/dev/null || nft list table inet incus_masq >/dev/null 2>&1 || return 1
        nft add chain inet incus_masq postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null ||
            nft list chain inet incus_masq postrouting >/dev/null 2>&1 || return 1
        add_nft_rule_once inet incus_masq postrouting 'oifname != "incusbr0" masquerade' oifname != "incusbr0" masquerade || return 1
        save_firewall_rules || return 1
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --zone=public --add-masquerade || return 1
        firewall-cmd --zone=trusted --change-interface=incusbr0 --permanent || return 1
        firewall-cmd --reload || return 1
    else
        # Fallback to iptables with persistence
        install_package iptables || return 1
        ensure_iptables_persistent || return 1
        add_iptables_masq_once || return 1
        save_firewall_rules || return 1
    fi
}

configure_uid_gid() {
  local UID_RANGE="${1:-100000:65536}"
  local FILES=(/etc/subuid /etc/subgid)
  local FILE
  if [[ ! "$UID_RANGE" =~ ^[0-9]+:[0-9]+$ ]]; then
    echo "Error: UID_RANGE '$UID_RANGE' is not in 'start:count' numeric format." >&2
    return 1
  fi
  for FILE in "${FILES[@]}"; do
    touch "$FILE" || return 1
    # Existing containers may use a custom range (or several ranges). Replacing
    # it on a repeated install can make those containers impossible to start.
    if grep -Eq '^root:[0-9]+:[0-9]+$' "$FILE"; then
        continue
    fi
    if grep -q '^root:' "$FILE"; then
        _red "Invalid existing root ID mapping in $FILE; preserving it for manual repair"
        return 1
    fi
    printf 'root:%s\n' "$UID_RANGE" >>"$FILE" || return 1
  done
}

copy_scripts_to_system() {
    local script
    for script in ssh_sh.sh ssh_bash.sh config.sh image_lookup.sh buildct.sh buildvm.sh instance_ops.sh macvlan.sh; do
        if [ -f "/root/$script" ]; then
            cp "/root/$script" /usr/local/bin/ || return 1
            chmod 755 "/usr/local/bin/$script" || return 1
        fi
    done
}

main() {
    init_env
    load_storage_state
    statistics_of_run_times
    install_dependencies || return 1
    rebuild_cloud_init
    check_cdn_file
    install_incus || return 1
    incus admin waitready --timeout=120 || return 1
    setup_firewall || return 1
    get_user_inputs
    setup_storage || return 1
    service_manager start incus 2>/dev/null || true
    sleep 3
    configure_incus_settings || return 1
    optimize_system || return 1
    setup_iptables || return 1
    configure_uid_gid || return 1
    download_preconfigured_files || return 1
    copy_scripts_to_system || return 1
    service_manager enable incus || return 1
    service_manager restart incus || return 1
    incus admin waitready --timeout=120 || return 1
    ensure_runtime_network || return 1
    install_dns_checker || return 1
    _green "脚本当天运行次数:${TODAY}，累计运行次数:${TOTAL}"
    _green "Incus Version: $(incus --version)"
    _green "The first startup may take 400~500 seconds at most, please be patient."
    _green "首次启动最多可能耗时在400~500秒，请耐心等待"
    if is_noninteractive; then
        _green "检测到 noninteractive=true，跳过自动重启。"
        _green "Detected noninteractive=true, skipping automatic reboot."
    else
        _green "You must reboot the machine to ensure user permissions are properly loaded. (The machine will restart automatically after 15 seconds)"
        _green "必须重启本机以保证用户权限正确加载。(15秒后本机将自动重启)"
        sleep 15 && reboot
    fi
}

if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    main
fi
