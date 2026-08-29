#!/bin/bash
# by hhttps://github.com/oneclickvirt/incus
# 2026.08.30

# 字体颜色函数
_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }

INCUS_STATE_DIR="${INCUS_STATE_DIR:-/usr/local/bin}"

state_file() {
    printf '%s/%s\n' "${INCUS_STATE_DIR%/}" "$1"
}

has_unsafe_scalar_chars() {
    local value="$1"
    [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\033'* ]]
}

valid_prefix_length() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" &&
        [[ "$value" =~ ^[0-9]+$ ]] &&
        [ "$value" -ge 1 ] && [ "$value" -le 128 ]
}

read_strict_prefix_file() {
    local file="$1" value line_count
    [ -f "$file" ] || return 1
    line_count=$(awk 'END { print NR + 0 }' "$file" 2>/dev/null) || return 1
    [ "$line_count" -eq 1 ] || return 1
    IFS= read -r value <"$file" || [ -n "$value" ] || return 1
    valid_prefix_length "$value" || return 1
    printf '%s\n' "$value"
}

read_strict_ipv6_file() {
    local file="$1" value line_count
    [ -f "$file" ] || return 1
    line_count=$(awk 'END { print NR + 0 }' "$file" 2>/dev/null) || return 1
    [ "$line_count" -eq 1 ] || return 1
    IFS= read -r value <"$file" || [ -n "$value" ] || return 1
    normalize_ipv6_address "$value"
}

write_atomic_scalar() {
    local file="$1" value="$2" dir tmp
    ! has_unsafe_scalar_chars "$value" && [ -n "$value" ] || return 1
    dir=${file%/*}
    [ "$dir" != "$file" ] || dir=.
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$value" >"$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

normalize_ipv6_address() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

raw = sys.argv[1].strip()
try:
    address = ipaddress.ip_address(raw.strip("[]"))
except ValueError:
    raise SystemExit(1)
if address.version != 6:
    raise SystemExit(1)
print(address.compressed)
PY
}

normalize_ipv6_interface() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    value = ipaddress.ip_interface(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)
if value.version != 6:
    raise SystemExit(1)
print(value.with_prefixlen)
PY
}

normalize_ipv6_network() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    value = ipaddress.ip_interface(sys.argv[1].strip()).network
except ValueError:
    raise SystemExit(1)
if value.version != 6:
    raise SystemExit(1)
print(value.with_prefixlen)
PY
}

generate_ipv6_candidates() {
    local network="$1" limit="${2:-65533}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$network" "$limit" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
    limit = int(sys.argv[2])
except (ValueError, IndexError):
    raise SystemExit(1)
if network.version != 6 or limit < 1:
    raise SystemExit(1)
start = 3 if network.num_addresses > 4 else 0
count = min(limit, network.num_addresses - start)
for offset in range(count):
    print(ipaddress.ip_address(int(network.network_address) + start + offset).compressed)
PY
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

# Resolve the interface that actually owns the selected global IPv6 address.
# Do not assume that the first physical NIC is the IPv6 uplink: HE/6in4,
# sit/vti/GRE and routed bridge deployments commonly terminate IPv6 elsewhere.
ipv6_uplink_interface() {
    local preferred="${1:-}" requested="${INCUS_IPV6_UPLINK:-}" iface fallback_iface raw cidr normalized network
    if [ -n "$requested" ] && [[ "$requested" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        if [ -z "$preferred" ] || ip -o -6 addr show dev "$requested" scope global 2>/dev/null | grep -q .; then
            printf '%s\n' "$requested"
            return 0
        fi
    fi
    if [ -n "$preferred" ]; then
        # The same address can legitimately exist as a host /128 and on a
        # delegated /38, /64 or /127 bridge. Prefer the interface whose
        # connected CIDR still has an address available for the guest.
        while read -r iface cidr; do
            [ -n "$iface" ] && [ -n "$cidr" ] || continue
            raw=${cidr%/*}
            normalized=$(normalize_ipv6_address "$raw" 2>/dev/null || true)
            [ "$normalized" = "$preferred" ] || continue
            fallback_iface="${fallback_iface:-$iface}"
            network=$(ipv6_allocation_network "$cidr" 2>/dev/null || true)
            if [ -n "$network" ] && ipv6_pool_has_extra_address "$network" "$normalized"; then
                printf '%s\n' "$iface"
                return 0
            fi
        done < <(ip -o -6 addr show scope global 2>/dev/null | awk '$4 ~ /^[^ ]+\/[0-9]+$/ {print $2, $4}')
        [ -n "$fallback_iface" ] && { printf '%s\n' "$fallback_iface"; return 0; }
    fi
    iface=$(ip -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [ -n "$iface" ] && ip -o -6 addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
        printf '%s\n' "$iface"
        return 0
    fi
    # Prefer common tunnel names when the provider has no default route yet.
    while IFS= read -r iface; do
        case "$iface" in
        he-ipv6 | sit* | ip6tnl* | 6in4* | vti* | gre*)
            if ip -o -6 addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
                printf '%s\n' "$iface"
                return 0
            fi
            ;;
        esac
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
    iface=$(detect_primary_ipv6_iface)
    [ -n "$iface" ] || return 1
    printf '%s\n' "$iface"
}

select_ipv6_interface() {
    local preferred_address="${1:-}" candidates="${2:-}"
    ! has_unsafe_scalar_chars "$preferred_address" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$preferred_address" "$candidates" <<'PY'
import ipaddress
import sys

preferred = sys.argv[1].strip()
values = []
for raw in sys.argv[2].splitlines():
    try:
        interface = ipaddress.ip_interface(raw.strip())
    except ValueError:
        continue
    if interface.version != 6:
        continue
    if preferred and interface.ip.compressed == preferred:
        print(interface.with_prefixlen)
        raise SystemExit(0)
    values.append(interface)
if values:
    print(values[0].with_prefixlen)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

ipv6_uplink_cidr() {
    local iface="$1" preferred="${2:-}" raw
    [ -n "$iface" ] || return 1
    raw=$(ip -o -6 addr show dev "$iface" scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    select_ipv6_interface "$preferred" "$raw"
}

# A host /128 is a single address, not an address pool.  Conversely, a
# routed/on-link /64, /38 or /127 may provide one or more additional addresses
# when the upstream supports NDP/routing.  Keep this arithmetic independent of
# hextet boundaries so non-nibble prefixes are handled correctly.
ipv6_allocation_network() {
    local detected="${1:-}" requested="${INCUS_IPV6_ROUTED_PREFIX:-}" value
    value="${requested:-$detected}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
except ValueError:
    raise SystemExit(1)
if network.version != 6 or network.prefixlen > 127:
    raise SystemExit(1)
if not network.subnet_of(ipaddress.IPv6Network("2000::/3")):
    raise SystemExit(1)
print(network.with_prefixlen)
PY
}

ipv6_pool_has_extra_address() {
    local network="$1" excluded="${2:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$network" "$excluded" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
    excluded = ipaddress.IPv6Address(sys.argv[2]) if sys.argv[2] else None
except ValueError:
    raise SystemExit(1)
if network.prefixlen > 127:
    raise SystemExit(1)
available = network.num_addresses - (1 if excluded is not None and excluded in network else 0)
raise SystemExit(0 if available > 0 else 1)
PY
}

disable_legacy_link_local_cleanup() {
    local legacy="${INCUS_LEGACY_FE80_CLEANUP:-/usr/local/bin/remove_route.sh}" current
    [ -f "$legacy" ] || return 0
    # Only touch the two-line helper generated by older versions of this
    # repository; an administrator script containing a similar command must
    # remain untouched.
    awk '
        BEGIN { commands = 0; valid = 1 }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        /^[[:space:]]*ip([[:space:]]+-6)?[[:space:]]+addr[[:space:]]+del[[:space:]]+fe80:[0-9A-Fa-f:]+(\/[0-9]+)?[[:space:]]+dev[[:space:]]+[A-Za-z0-9_.:-]+[[:space:]]*$/ { commands++; next }
        { valid = 0 }
        END { exit !(valid && commands == 1) }
    ' "$legacy" || return 0
    if command -v crontab >/dev/null 2>&1; then
        current=$(crontab -l 2>/dev/null || true)
        if printf '%s\n' "$current" | grep -Fq "$legacy"; then
            printf '%s\n' "$current" |
                awk -v path="$legacy" '{ line = $0; sub(/^[[:space:]]*@reboot[[:space:]]+/, "", line); if (line != path) print }' |
                crontab - 2>/dev/null || true
        fi
    fi
    rm -f -- "$legacy"
}

configure_ipv6_nat66_fallback() {
    local network="${INCUS_IPV6_NETWORK:-incusbr0}" parent current existing_mode
    if command -v incus >/dev/null 2>&1 && [ -n "${CONTAINER_NAME:-}" ]; then
        parent=$(incus config device get "$CONTAINER_NAME" eth0 parent 2>/dev/null || true)
        [[ "$parent" =~ ^[A-Za-z0-9_.:-]+$ ]] && network="$parent"
        current=$(incus network get "$network" ipv6.address 2>/dev/null || true)
        if [ -z "$current" ] || [ "$current" = "none" ]; then
            incus network set "$network" ipv6.address auto 2>/dev/null || true
        fi
        incus network set "$network" ipv6.nat true 2>/dev/null || true
    fi
    existing_mode=$(cat "$(state_file incus_ipv6_mode)" 2>/dev/null || true)
    if [ "$existing_mode" != routed ] && [ "$existing_mode" != public-nat ] &&
        [ ! -s "$(state_file incus_ipv6_mapping_interface)" ]; then
        write_atomic_scalar "$(state_file incus_ipv6_mode)" nat66 2>/dev/null || true
    fi
    _yellow "No additional routed IPv6 address is available; retaining the container IPv6 network and enabling NAT66 where supported."
    _yellow "宿主机没有可分配的额外公网 IPv6；保留容器 IPv6 网络，并在支持时启用 NAT66。"
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
    local cache_file cached_val rdisc6_output real_prefixlen selected_prefixlen
    cache_file=$(state_file incus_ipv6_real_prefixlen)

    # 缓存必须是严格的单行整数。禁止把多行诊断通过删除空白拼成值。
    if [ -f "$cache_file" ]; then
        if cached_val=$(read_strict_prefix_file "$cache_file"); then
            printf '%s\n' "$cached_val"
            return 0
        else
            _yellow "Cached IPv6 prefix length is not one clean value, re-detecting..." >&2
            _yellow "缓存的 IPv6 前缀长度不是单一干净值，重新检测..." >&2
            rm -f "$cache_file"
        fi
    fi

    # 缓存无效或不存在，尝试从路由器通告获取
    if command -v rdisc6 >/dev/null 2>&1; then
        _blue "Attempting to get real IPv6 prefix from router advertisement..." >&2
        _green "尝试从路由器通告中获取真实的 IPv6 前缀..." >&2
        _blue "Using network interface: ${interface}" >&2
        _green "正在使用网络接口: ${interface}" >&2

        rdisc6_output=$(timeout 10 rdisc6 "${interface}" 2>/dev/null)

        if [ -n "$rdisc6_output" ]; then
            # 从路由器通告中提取前缀长度
            if [ "$GREP_PERL_SUPPORT" = true ]; then
                # 如果支持 Perl 正则，使用 grep -oP（更精确）
                real_prefixlen=$(echo "$rdisc6_output" | safe_grep "Prefix" | grep -oP '[:：]\s*[0-9a-fA-F:]+/\K\d+' | head -n 1)
            else
                # 否则使用兼容的 sed 方式，避免 Perl 正则表达式依赖
                real_prefixlen=$(echo "$rdisc6_output" | safe_grep "Prefix" | sed -n 's/.*[：:][[:space:]]*\([0-9a-fA-F:][0-9a-fA-F:]*\)\/\([0-9][0-9]*\).*/\2/p' | head -n 1)
            fi

            # 验证路由器通告的前缀长度必须在 1-128 之间
            if valid_prefix_length "$real_prefixlen"; then
                _green "Found real IPv6 prefix length from router advertisement: /$real_prefixlen" >&2
                _green "从路由器通告中发现真实的 IPv6 前缀长度: /$real_prefixlen" >&2
                selected_prefixlen="$current_prefixlen"
                if ! valid_prefix_length "$selected_prefixlen"; then
                    selected_prefixlen="$real_prefixlen"
                fi

                # 规则1: OS 报告的前缀比路由器更宽泛（数字更小），使用路由器更精确的前缀
                #        例如 OS=/48, 路由器=/64 → 使用 /64（更符合实际分配的子网）
                if valid_prefix_length "$current_prefixlen" && [ "$current_prefixlen" -lt "$real_prefixlen" ]; then
                    _green "Using more specific prefix /$real_prefixlen from router advertisement (OS reported /$current_prefixlen)" >&2
                    _green "使用路由器通告的更精确前缀 /${real_prefixlen}（OS 报告为 /${current_prefixlen}）" >&2
                    selected_prefixlen="$real_prefixlen"
                fi

                # 规则2: OS 报告的前缀过于精确（如 /128 主机路由），而路由器通告的是可用子网（≤64）
                #        这种情况发生在 SLAAC 或 DHCPv6 给宿主机分配了 /128，但实际子网是 /64
                if valid_prefix_length "$current_prefixlen" && [ "$current_prefixlen" -gt 64 ] && [ "$real_prefixlen" -le 64 ]; then
                    _yellow "Current prefix /$current_prefixlen is a host route; using router-advertised subnet /$real_prefixlen" >&2
                    _yellow "当前前缀 /$current_prefixlen 为主机路由，使用路由器通告的子网 /$real_prefixlen" >&2
                    selected_prefixlen="$real_prefixlen"
                fi
                write_atomic_scalar "$cache_file" "$selected_prefixlen" || return 1
                printf '%s\n' "$selected_prefixlen"
                return 0
            else
                _yellow "Could not parse a valid IPv6 prefix length from router advertisement" >&2
                _yellow "无法从路由器通告中解析有效的 IPv6 前缀长度" >&2
            fi
        else
            _yellow "Could not get router advertisement response on interface ${interface} (timeout or no response)" >&2
            _yellow "无法在接口 ${interface} 获取路由器通告响应(超时或无响应)" >&2
        fi
    fi

    if valid_prefix_length "$current_prefixlen"; then
        write_atomic_scalar "$cache_file" "$current_prefixlen" || return 1
        printf '%s\n' "$current_prefixlen"
        return 0
    fi
    _yellow "Current IPv6 prefix length is invalid; refusing to guess /64" >&2
    _yellow "当前 IPv6 前缀长度无效，拒绝猜测为 /64" >&2
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
    _yellow "Re-trying installation of ${pkg}…"
    _yellow "正在重试安装 ${pkg}…"
    if $PACKAGETYPE_INSTALL "$pkg"; then
        _green "$pkg has been installed (with EPEL/CRB)"
        _green "$pkg 安装成功（利用 EPEL/CRB）"
        return 0
    fi
    if command -v pip3 &>/dev/null; then
        _yellow "Attempting pip3 install for ${pkg}…"
        _yellow "尝试通过 pip3 安装 ${pkg}…"
        if pip3 install --user "$pkg"; then
            _green "$pkg installed via pip3 (in ~/.local/bin)"
            _green "$pkg 已通过 pip3 安装（位于 ~/.local/bin）"
            return 0
        fi
    fi
    _red "ERROR: Unable to install $pkg – please check repos or install manually"
    _red "错误：无法安装 ${pkg}，请检查仓库或手动安装"
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

# Check whether an IPv6 address is a usable GUA allocation source. Textual
# prefix tests are unsafe because the same address may contain leading zeros.
is_public_ipv6() {
    local address="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$address" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_private
    and not address.is_multicast
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
}

# 检查是否为私有IPv6地址
is_private_ipv6() {
    ! is_public_ipv6 "${1:-}"
}

# 检查IPv6地址
check_ipv6() {
    local candidate cache_file normalized prefix fallback network
    cache_file=$(state_file incus_check_ipv6)
    IPV6=""
    fallback=""
    while IFS= read -r candidate; do
        prefix="${candidate##*/}"
        candidate=${candidate%/*}
        if normalized=$(normalize_ipv6_address "$candidate" 2>/dev/null) && ! is_private_ipv6 "$normalized"; then
            fallback="${fallback:-$normalized}"
            # Do not let a host-only /128 shadow a usable delegated prefix on
            # another bridge that carries the same address.
            if network=$(ipv6_allocation_network "${normalized}/${prefix}" 2>/dev/null) &&
                ipv6_pool_has_extra_address "$network" "$normalized"; then
                IPV6="$normalized"
                break
            fi
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    [ -n "$IPV6" ] || IPV6="$fallback"
    if [ -z "$IPV6" ]; then
        _red "No locally bound public IPv6 address is available" >&2
        _red "未检测到本机绑定的公网 IPv6 地址" >&2
        return 1
    fi
    write_atomic_scalar "$cache_file" "$IPV6"
    printf '%s\n' "$IPV6"
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
    ipv6=$(incus list "$container_name" --format=json 2>/dev/null | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet6") | select(.scope=="global") | .address' 2>/dev/null | head -n 1)
    if ! ipv6=$(normalize_ipv6_address "$ipv6" 2>/dev/null); then
        _red "Container has no single valid intranet IPv6 address, no auto-mapping" >&2
        _red "容器没有单一有效的内网 IPv6 地址，不进行自动映射" >&2
        return 1
    fi
    _blue "The container with the name $container_name has an intranet IPV6 address of $ipv6" >&2
    _blue "$container_name 容器的内网IPV6地址为 $ipv6" >&2
    printf '%s\n' "$ipv6"
}

# 获取宿主机IPv6子网前缀
get_host_ipv6_prefix() {
    local raw_cidr="${1:-}" prefix
    if [ -z "$raw_cidr" ]; then
        raw_cidr=$(ip -6 addr show 2>/dev/null | awk '$1 == "inet6" && $0 ~ /scope global/ {print $2; exit}')
    fi
    if ! prefix=$(normalize_ipv6_network "$raw_cidr" 2>/dev/null); then
        _red "No valid IPv6 subnet, no automatic mapping" >&2
        _red "没有有效的 IPv6 子网，不进行自动映射" >&2
        return 1
    fi
    _blue "The IPv6 subnet is $prefix" >&2
    _blue "宿主机的 IPv6 子网为 $prefix" >&2
    printf '%s\n' "$prefix"
}

# 获取IPv6网关信息
get_ipv6_gateway_info() {
    local output
    local num_lines
    output=$(ip -6 route show | awk '/default via/{print $3}')
    num_lines=$(echo "$output" | wc -l)
    local ipv6_gateway=""
    if [ "$num_lines" -eq 1 ]; then
        ipv6_gateway="$output"
    elif [ "$num_lines" -ge 2 ]; then
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
    local ipv6_cache network_cidr host_ipv6 candidate found_ipv6
    ipv6_cache=$(state_file incus_check_ipv6)
    if ! IPV6=$(read_strict_ipv6_file "$ipv6_cache" 2>/dev/null); then
        check_ipv6 || return 1
        IPV6=$(read_strict_ipv6_file "$ipv6_cache" 2>/dev/null) || return 1
    fi
    ipv6_network_name=$(ipv6_uplink_interface "$IPV6" 2>/dev/null || true)
    ip_network_gam=$(ipv6_uplink_cidr "$ipv6_network_name" "$IPV6" 2>/dev/null || true)
    _yellow "Local IPV6 address: $ip_network_gam"
    if [ -n "$ip_network_gam" ] && [ -n "$ipv6_network_name" ]; then
        if ! ip_network_gam=$(normalize_ipv6_interface "$ip_network_gam" 2>/dev/null); then
            _red "Local IPv6 interface value is invalid" >&2
            return 1
        fi
        # The kernel-advertised CIDR is authoritative for allocation.  Router
        # advertisements are diagnostic only; replacing a host /128 with an
        # RA /64 would incorrectly manufacture a public address pool.
        network_cidr=$(ipv6_allocation_network "$ip_network_gam" 2>/dev/null || true)
        host_ipv6=$(normalize_ipv6_address "${ip_network_gam%/*}" 2>/dev/null || true)
    fi
    if [ -n "${network_cidr:-}" ] && [ -n "${host_ipv6:-}" ] && ipv6_pool_has_extra_address "$network_cidr" "$host_ipv6"; then
        # Linux suppresses ordinary router advertisements after forwarding is
        # enabled unless the uplink explicitly opts in. Keep SLAAC routes.
        update_sysctl "net.ipv6.conf.${ipv6_network_name}.accept_ra=2"
        # Proxying is needed only on the actual uplink. Do not make unrelated
        # bridges and interfaces inherit NDP proxy behavior.
        update_sysctl "net.ipv6.conf.${ipv6_network_name}.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.all.forwarding=1"
        sysctl_path=$(which sysctl)
        ${sysctl_path} -p
        found_ipv6=""
        while IFS= read -r candidate; do
            [ "$candidate" = "$host_ipv6" ] && continue
            ip -6 addr show dev "$ipv6_network_name" 2>/dev/null | grep -Fqw "$candidate" && continue
            if ! ping6 -c1 -w1 -q "$candidate" >/dev/null 2>&1; then
                found_ipv6="$candidate"
                break
            fi
        done < <(generate_ipv6_candidates "$network_cidr" 65533)
        if [ -z "$found_ipv6" ]; then
            _red "No available IPv6 address in $network_cidr" >&2
            return 1
        fi
        incus_ipv6="$found_ipv6"
        _green "Conatiner $container_name IPV6:"
        _green "$incus_ipv6"
        incus stop "$container_name"
        sleep 3
        wait_for_container_stopped "$container_name"
        incus config device remove "$container_name" eth1 >/dev/null 2>&1 || true
        incus config device add "$container_name" eth1 nic nictype=routed parent="$ipv6_network_name" ipv6.address="$incus_ipv6" || return 1
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
        # A link-local address is required for RA/NDP and must never be
        # deleted merely because the default route uses a global gateway.
        disable_legacy_link_local_cleanup
        if [[ "$ipv6_gateway_fe80" == "Y" ]]; then
            _blue "Retaining the link-local IPv6 gateway on ${ipv6_network_name}."
        fi
        local cron_line
        cron_line='*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb'
        if ! crontab -l 2>/dev/null | grep -Fqx "$cron_line"; then
            (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        fi
        echo "$incus_ipv6" >>"$container_name"_v6
        write_atomic_scalar "$(state_file incus_ipv6_mode)" routed || true
    else
        _red "The selected IPv6 prefix has no additional address (a /128 host route is not a pool)." >&2
        _red "所选 IPv6 前缀没有可分配的额外地址（宿主 /128 不是地址池）。" >&2
        configure_ipv6_nat66_fallback
        return 0
    fi
}

setup_iptables_ipv6() {
    local container_name=$1
    local container_ipv6=$2
    local subnet_prefix=$3
    local ipv6_length=$4
    local interface=$5
    if ! subnet_prefix=$(ipv6_allocation_network "$subnet_prefix" 2>/dev/null); then
        configure_ipv6_nat66_fallback
        return 0
    fi
    if ! ipv6_pool_has_extra_address "$subnet_prefix" "${IPV6:-}"; then
        configure_ipv6_nat66_fallback
        return 0
    fi
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
    # CIDR arithmetic handles /80 through /128 without fixed-hextet string concatenation.
    local candidate found_ipv6=""
    while IFS= read -r candidate; do
        IPV6="$candidate"
        [[ $IPV6 == "$container_ipv6" ]] && continue
        ip -6 addr show dev "$interface" | grep -qw "$IPV6" && continue
        if ! ping6 -c1 -w1 -q "$IPV6" &>/dev/null; then
            if [ "$use_nft" = true ]; then
                if ! nft list ruleset 2>/dev/null | grep -q "dnat ip6 to $container_ipv6" 2>/dev/null || ! nft list ruleset 2>/dev/null | grep -q "$IPV6" 2>/dev/null; then
                    _green "$IPV6"
                    found_ipv6="$IPV6"
                    break
                fi
            else
                if ! ip6tables -t nat -C PREROUTING -d "$IPV6" -j DNAT --to-destination "$container_ipv6" &>/dev/null; then
                    _green "$IPV6"
                    found_ipv6="$IPV6"
                    break
                fi
            fi
        fi
        _yellow "$IPV6"
    done < <(generate_ipv6_candidates "$subnet_prefix" 65533)
    IPV6="$found_ipv6"
    if [ -z "$IPV6" ]; then
        _red "No IPV6 address available, no auto mapping"
        _red "无可用 IPV6 地址，不进行自动映射"
        exit 1
    fi
    valid_prefix_length "$ipv6_length" || return 1
    write_atomic_scalar "$(state_file incus_ipv6_mapping_interface)" "$interface" || return 1
    write_atomic_scalar "$(state_file incus_ipv6_mapping_prefix_len)" "$ipv6_length" || return 1
    write_atomic_scalar "$(state_file incus_ipv6_mode)" public-nat || return 1
    ip -6 addr replace "$IPV6"/"$ipv6_length" dev "$interface" || return 1
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
        wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/add-ipv6.sh" -O /usr/local/bin/add-ipv6.sh
        chmod +x /usr/local/bin/add-ipv6.sh
    fi
    if [ ! -f /etc/systemd/system/add-ipv6.service ]; then
        wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/add-ipv6.service" -O /etc/systemd/system/add-ipv6.service
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
    disable_legacy_link_local_cleanup
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
    install_package python3
    if ! IPV6=$(check_ipv6 2>/dev/null); then
        configure_ipv6_nat66_fallback
        return 0
    fi
    interface=$(ipv6_uplink_interface "$IPV6" 2>/dev/null || true)
    if [ -z "$interface" ] || has_unsafe_scalar_chars "$interface" || [[ ! "$interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        _red "Unable to detect one valid network interface" >&2
        configure_ipv6_nat66_fallback
        return 0
    fi
    _yellow "NIC $interface"
    _yellow "网卡 $interface"
    incus start "$CONTAINER_NAME"
    sleep 3
    wait_for_container_running "$CONTAINER_NAME"
    if ! CONTAINER_IPV6=$(get_container_ipv6 "$CONTAINER_NAME"); then
        configure_ipv6_nat66_fallback
        return 0
    fi
    ipv6_address=$(ipv6_uplink_cidr "$interface" "$IPV6" 2>/dev/null || true)
    ipv6_address=$(normalize_ipv6_interface "$ipv6_address" 2>/dev/null) || {
        _red "Unable to detect one valid host IPv6 interface address" >&2
        configure_ipv6_nat66_fallback
        return 0
    }
    if [[ $ipv6_address == */* ]]; then
        ipv6_length=$(echo "$ipv6_address" | awk -F '/' '{ print $2 }')
        valid_prefix_length "$ipv6_length" || exit 1
        ipv6_address=$(normalize_ipv6_interface "$ipv6_address" 2>/dev/null) || exit 1
        _green "subnet size: $ipv6_length"
        _green "子网大小: $ipv6_length"
    else
        _green "Subnet size for IPV6 not queried"
        _green "查询不到IPV6的子网大小"
        exit 1
    fi
    if ! SUBNET_PREFIX=$(ipv6_allocation_network "$ipv6_address" 2>/dev/null) ||
        ! ipv6_pool_has_extra_address "$SUBNET_PREFIX" "${ipv6_address%/*}"; then
        configure_ipv6_nat66_fallback
        return 0
    fi
    ipv6_gateway_fe80=$(get_ipv6_gateway_info)
    if [[ $use_iptables == n ]]; then
        setup_network_device_ipv6 "$CONTAINER_NAME" "$CONTAINER_IPV6" "$ipv6_gateway_fe80" || return 1
    else
        setup_iptables_ipv6 "$CONTAINER_NAME" "$CONTAINER_IPV6" "$SUBNET_PREFIX" "$ipv6_length" "$interface" || return 1
    fi
}

if [ "${ONECLICKVIRT_TESTING:-0}" != "1" ]; then
    main "$@"
fi
