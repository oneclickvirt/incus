#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2025.08.26

INSTALL_PATH="/usr/local/bin/incus_fixed_restart.sh"
LOG_FILE="/usr/local/bin/incus_fixed_restart.log"
COUNTER_FILE="/usr/local/bin/incus_fixed_restart_counter"
SERVICE_NAME="incus"
PROCESS_NAME="incusd"
CPU_THRESHOLD=80.0
MAX_COUNT=3
MAX_LOG_LINES=1000

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

restart_service() {
    systemctl restart "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
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
        reset_counter
        trim_log
        exit 0
    fi
    cpu_usage_num=$(echo "$cpu_usage" | sed 's/%//g')
    if [ "$(echo "$cpu_usage_num > $CPU_THRESHOLD" | bc -l)" -eq 1 ]; then
        counter=$(increment_counter)
        echo "$current_time - $PROCESS_NAME CPU usage: $cpu_usage_num%, counter: $counter" >> "$LOG_FILE"
        if [ "$counter" -ge "$MAX_COUNT" ]; then
            echo "$current_time - $PROCESS_NAME CPU usage exceeded $CPU_THRESHOLD% for $MAX_COUNT minutes, restarting $SERVICE_NAME…" >> "$LOG_FILE"
            restart_service
            echo "$current_time - $SERVICE_NAME restart complete" >> "$LOG_FILE"
            reset_counter
        fi
    else
        reset_counter
        echo "$current_time - $PROCESS_NAME CPU usage: $cpu_usage_num%, normal" >> "$LOG_FILE"
    fi
    trim_log
}

install_self() {
    if [ "$0" != "$INSTALL_PATH" ]; then
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo "Installed to $INSTALL_PATH"
    fi
    crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"
    if [ $? -ne 0 ]; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * $INSTALL_PATH") | crontab -
        echo "Cron job installed"
    else
        echo "Cron job already exists"
    fi
}

uninstall_self() {
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    echo "Cron job removed"
    rm -f "$INSTALL_PATH"
    rm -f "$LOG_FILE"
    rm -f "$COUNTER_FILE"
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
