#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2025.06.26

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
        daemon-reload)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl daemon-reload 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                # OpenRC doesn't need daemon-reload
                executed=true
                success=true
            fi
            ;;
        daemon-reexec)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl daemon-reexec 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                # OpenRC doesn't need daemon-reexec
                executed=true
                success=true
            fi
            ;;
        is-enabled)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
                    return 0
                fi
            fi
            if command -v rc-update >/dev/null 2>&1; then
                if rc-update show | grep -q "^\s*$service_name\s*|"; then
                    return 0
                fi
            fi
            if command -v chkconfig >/dev/null 2>&1; then
                if chkconfig "$service_name" 2>/dev/null | grep -q "on"; then
                    return 0
                fi
            fi
            return 1
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

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
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
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
    fi
}

ensure_coexistence_setup() {
    local base_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/extra_scripts"
    local script_dir="/usr/local/bin"
    local systemd_dir="/etc/systemd/system"
    if [ ! -f "${script_dir}/coexistence.sh" ]; then
        echo "Downloading coexistence.sh..."
        curl -fsSL "${base_url}/coexistence.sh" -o "${script_dir}/coexistence.sh" || {
            echo "Failed to download coexistence.sh"
            return 1
        }
        chmod +x "${script_dir}/coexistence.sh"
    fi
    if [ ! -f "${systemd_dir}/coexistence.service" ]; then
        echo "Downloading coexistence.service..."
        curl -fsSL "${base_url}/coexistence.service" -o "${systemd_dir}/coexistence.service" || {
            echo "Failed to download coexistence.service"
            return 1
        }
    fi
    if [ ! -f "${systemd_dir}/coexistence.timer" ]; then
        echo "Downloading coexistence.timer..."
        curl -fsSL "${base_url}/coexistence.timer" -o "${systemd_dir}/coexistence.timer" || {
            echo "Failed to download coexistence.timer"
            return 1
        }
    fi
    echo "Reloading systemd daemon..."
    service_manager daemon-reexec
    service_manager daemon-reload
    for unit in coexistence.service coexistence.timer; do
        if ! service_manager is-enabled "$unit"; then
            echo "Enabling $unit..."
            service_manager enable "$unit"
        fi
        if ! service_manager is-active "$unit"; then
            echo "Starting $unit..."
            service_manager start "$unit"
        fi
    done
    echo "Done!"
}

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
check_cdn_file
ensure_coexistence_setup
