#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2025.06.26

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
    systemctl daemon-reexec
    systemctl daemon-reload
    for unit in coexistence.service coexistence.timer; do
        if ! systemctl is-enabled --quiet "$unit"; then
            echo "Enabling $unit..."
            systemctl enable "$unit"
        fi
        if ! systemctl is-active --quiet "$unit"; then
            echo "Starting $unit..."
            systemctl start "$unit"
        fi
    done
    echo "Done!"
}

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
check_cdn_file
ensure_coexistence_setup
