#!/usr/bin/env bash
# from https://github.com/oneclickvirt/incus
# macvlan profile helper for Incus instances.

set -euo pipefail

red() { echo -e "\033[31m\033[01m$*\033[0m"; }
green() { echo -e "\033[32m\033[01m$*\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }

usage() {
    cat <<'EOF'
Usage:
  macvlan.sh create-profile [PROFILE] [PARENT]
  macvlan.sh attach INSTANCE [PROFILE]
  macvlan.sh detach INSTANCE [PROFILE]
  macvlan.sh delete-profile [PROFILE]

Environment fallback:
  INCUS_MACVLAN_ACTION=create-profile|attach|detach|delete-profile
  INCUS_MACVLAN_INSTANCE=name
  INCUS_MACVLAN_PROFILE=macvlan
  INCUS_MACVLAN_PARENT=eth0
EOF
}

require_incus() {
    if ! command -v incus >/dev/null 2>&1; then
        red "Incus command not found."
        red "未找到 incus 命令。"
        exit 1
    fi
}

default_parent() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$iface" ]; then
        for iface_path in /sys/class/net/*; do
            [ -e "$iface_path" ] || continue
            iface="${iface_path##*/}"
            case "$iface" in
            lo | veth* | br* | incus* | docker* | tap*) continue ;;
            esac
            break
        done
    fi
    echo "${iface:-eth0}"
}

profile_exists() {
    incus profile show "$1" >/dev/null 2>&1
}

create_profile() {
    local profile="${1:-macvlan}"
    local parent="${2:-}"
    [ -z "$parent" ] && parent="$(default_parent)"
    if ! profile_exists "$profile"; then
        incus profile create "$profile"
    fi
    if incus profile device show "$profile" 2>/dev/null | grep -q '^eth0:'; then
        incus profile device set "$profile" eth0 nictype macvlan
        incus profile device set "$profile" eth0 parent "$parent"
        incus profile device set "$profile" eth0 name eth0
    else
        incus profile device add "$profile" eth0 nic nictype=macvlan parent="$parent" name=eth0
    fi
    green "macvlan profile ready: $profile (parent=$parent)"
    green "macvlan 配置已就绪：$profile (parent=$parent)"
}

profile_attached() {
    local instance="$1"
    local profile="$2"
    incus config show "$instance" 2>/dev/null | awk '
        /^profiles:/ { in_profiles = 1; next }
        in_profiles && /^[[:space:]]*-/ { print $2; next }
        in_profiles && /^[^[:space:]-]/ { in_profiles = 0 }
    ' | grep -Fx "$profile" >/dev/null 2>&1
}

attach_profile() {
    local instance="$1"
    local profile="${2:-macvlan}"
    if [ -z "$instance" ]; then
        red "Missing INSTANCE"
        red "缺少 INSTANCE"
        exit 1
    fi
    profile_exists "$profile" || create_profile "$profile" "${INCUS_MACVLAN_PARENT:-}"
    if profile_attached "$instance" "$profile"; then
        yellow "Profile already attached: $profile"
        yellow "配置已存在：$profile"
        return
    fi
    incus profile add "$instance" "$profile"
    green "Profile attached: $instance <- $profile"
    green "配置已挂载：$instance <- $profile"
}

detach_profile() {
    local instance="$1"
    local profile="${2:-macvlan}"
    if [ -z "$instance" ]; then
        red "Missing INSTANCE"
        red "缺少 INSTANCE"
        exit 1
    fi
    if profile_attached "$instance" "$profile"; then
        incus profile remove "$instance" "$profile"
    fi
    green "Profile detached if present: $instance <- $profile"
    green "如存在则已卸载配置：$instance <- $profile"
}

delete_profile() {
    local profile="${1:-macvlan}"
    if profile_exists "$profile"; then
        incus profile delete "$profile"
    fi
    green "Profile deleted if present: $profile"
    green "如存在则已删除配置：$profile"
}

main() {
    local action="${1:-${INCUS_MACVLAN_ACTION:-}}"
    local profile="${2:-${INCUS_MACVLAN_PROFILE:-macvlan}}"
    case "$action" in
    -h | --help | help | "")
        usage
        return 0
        ;;
    esac

    require_incus
    case "$action" in
    create-profile)
        create_profile "$profile" "${3:-${INCUS_MACVLAN_PARENT:-}}"
        ;;
    attach)
        attach_profile "${2:-${INCUS_MACVLAN_INSTANCE:-}}" "${3:-${INCUS_MACVLAN_PROFILE:-macvlan}}"
        ;;
    detach)
        detach_profile "${2:-${INCUS_MACVLAN_INSTANCE:-}}" "${3:-${INCUS_MACVLAN_PROFILE:-macvlan}}"
        ;;
    delete-profile)
        delete_profile "$profile"
        ;;
    *)
        red "Unknown action: $action"
        red "未知操作：$action"
        usage
        exit 1
        ;;
    esac
}

main "$@"
