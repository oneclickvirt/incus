#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2025.10.14

INSTALL_PATH="/usr/local/bin/incus_fixed_restart.sh"
LOG_FILE="/usr/local/bin/incus_fixed_restart.log"
COUNTER_FILE="/usr/local/bin/incus_fixed_restart_counter"
CPULIMIT_PID_FILE="/usr/local/bin/incus_cpulimit.pid"
SERVICE_NAME="incus"
PROCESS_NAME="incusd"
CPU_THRESHOLD=80.0
CPU_LIMIT=70
MAX_COUNT=3
MAX_LOG_LINES=1000

get_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v apk &> /dev/null; then
        echo "apk"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo ""
    fi
}

install_cpulimit() {
    local pkg_manager
    pkg_manager=$(get_package_manager)
    
    if [ -z "$pkg_manager" ]; then
        echo "$(get_timestamp) - Error: Could not detect package manager" >> "$LOG_FILE"
        return 1
    fi
    
    if command -v cpulimit &> /dev/null; then
        echo "$(get_timestamp) - cpulimit already installed" >> "$LOG_FILE"
        return 0
    fi
    
    echo "$(get_timestamp) - Installing cpulimit via $pkg_manager..." >> "$LOG_FILE"
    
    case "$pkg_manager" in
        apt)
            sudo apt-get install -y cpulimit >> "$LOG_FILE" 2>&1
            ;;
        yum)
            sudo yum install -y cpulimit >> "$LOG_FILE" 2>&1
            ;;
        dnf)
            sudo dnf install -y cpulimit >> "$LOG_FILE" 2>&1
            ;;
        pacman)
            sudo pacman -S --noconfirm cpulimit >> "$LOG_FILE" 2>&1
            ;;
        apk)
            sudo apk add --no-cache cpulimit >> "$LOG_FILE" 2>&1
            ;;
        zypper)
            sudo zypper install -y cpulimit >> "$LOG_FILE" 2>&1
            ;;
    esac
    
    if command -v cpulimit &> /dev/null; then
        echo "$(get_timestamp) - cpulimit installed successfully" >> "$LOG_FILE"
        return 0
    else
        echo "$(get_timestamp) - Error: Failed to install cpulimit" >> "$LOG_FILE"
        return 1
    fi
}

init_counter() {
    if [ ! -f "$COUNTER_FILE" ]; then
        echo "0" > "$COUNTER_FILE"
    fi
}

get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

get_cpu_usage() {
    sleep 1
    top -b -n1 | grep "$PROCESS_NAME" | grep -v grep | awk '{print $9}' | sort -nr | head -n 1
}

reset_counter() {
    echo "0" > "$COUNTER_FILE"
}

increment_counter() {
    local counter
    counter=$(<"$COUNTER_FILE")
    counter=$((counter + 1))
    echo "$counter" > "$COUNTER_FILE"
    echo "$counter"
}

apply_cpulimit() {
    local pid
    pid=$(pgrep "$PROCESS_NAME" | head -n 1)
    
    if [ -z "$pid" ]; then
        echo "$(get_timestamp) - Error: $PROCESS_NAME process not found" >> "$LOG_FILE"
        return 1
    fi
    
    if [ -f "$CPULIMIT_PID_FILE" ]; then
        local old_pid
        old_pid=$(<"$CPULIMIT_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "$(get_timestamp) - cpulimit already running (PID: $old_pid)" >> "$LOG_FILE"
            return 0
        fi
    fi
    
    echo "$(get_timestamp) - Applying CPU limit ($CPU_LIMIT%) to $PROCESS_NAME (PID: $pid)" >> "$LOG_FILE"
    sudo cpulimit -e "$PROCESS_NAME" -l "$CPU_LIMIT" -b >> "$LOG_FILE" 2>&1 &
    echo $! > "$CPULIMIT_PID_FILE"
    
    return 0
}

remove_cpulimit() {
    if [ -f "$CPULIMIT_PID_FILE" ]; then
        local pid
        pid=$(<"$CPULIMIT_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$(get_timestamp) - Stopping cpulimit (PID: $pid)" >> "$LOG_FILE"
            sudo kill "$pid" 2>/dev/null
            rm -f "$CPULIMIT_PID_FILE"
        fi
    fi
}

trim_log() {
    if [ -f "$LOG_FILE" ]; then
        local lines
        lines=$(wc -l < "$LOG_FILE")
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

monitor_incusd() {
    init_counter
    local current_time cpu_usage cpu_usage_num counter
    current_time=$(get_timestamp)
    cpu_usage=$(get_cpu_usage)
    
    if [ -z "$cpu_usage" ]; then
        echo "$current_time - $PROCESS_NAME is not running" >> "$LOG_FILE"
        remove_cpulimit
        reset_counter
        trim_log
        exit 0
    fi
    
    cpu_usage_num=$(echo "$cpu_usage" | sed 's/%//g')
    
    if [ "$(echo "$cpu_usage_num > $CPU_THRESHOLD" | bc -l)" -eq 1 ]; then
        counter=$(increment_counter)
        echo "$current_time - $PROCESS_NAME CPU usage: $cpu_usage_num%, counter: $counter" >> "$LOG_FILE"
        
        if [ "$counter" -ge "$MAX_COUNT" ]; then
            echo "$current_time - $PROCESS_NAME CPU usage exceeded $CPU_THRESHOLD% for $MAX_COUNT times, applying cpulimit…" >> "$LOG_FILE"
            apply_cpulimit
        fi
    else
        if [ "$counter" -gt 0 ]; then
            echo "$current_time - $PROCESS_NAME CPU usage: $cpu_usage_num%, back to normal, removing limit…" >> "$LOG_FILE"
            remove_cpulimit
        fi
        reset_counter
        echo "$current_time - $PROCESS_NAME CPU usage: $cpu_usage_num%, normal" >> "$LOG_FILE"
    fi
    
    trim_log
}

install_self() {
    install_cpulimit
    
    if [ "$0" != "$INSTALL_PATH" ]; then
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo "Installed to $INSTALL_PATH"
    fi
    
    crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"
    if [ $? -ne 0 ]; then
        (crontab -l 2>/dev/null; echo "*/1 * * * * $INSTALL_PATH") | crontab -
        echo "Cron job installed (runs every minute)"
    else
        echo "Cron job already exists"
    fi
}

uninstall_self() {
    remove_cpulimit
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    echo "Cron job removed"
    rm -f "$INSTALL_PATH"
    rm -f "$LOG_FILE"
    rm -f "$COUNTER_FILE"
    rm -f "$CPULIMIT_PID_FILE"
    echo "Files removed"
}

case "$1" in
    install)
        install_self
        ;;
    uninstall)
        uninstall_self
        ;;
    *)
        monitor_incusd
        ;;
esac
