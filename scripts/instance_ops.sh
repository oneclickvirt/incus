#!/usr/bin/env bash
# from https://github.com/oneclickvirt/incus
# Instance snapshot, backup, restore and migration helper.

set -euo pipefail

red() { echo -e "\033[31m\033[01m$*\033[0m"; }
green() { echo -e "\033[32m\033[01m$*\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }

usage() {
    cat <<'EOF'
Usage:
  instance_ops.sh snapshot INSTANCE [SNAPSHOT]
  instance_ops.sh backup INSTANCE [ARCHIVE]
  instance_ops.sh restore ARCHIVE [INSTANCE]
  instance_ops.sh migrate INSTANCE REMOTE [TARGET] [copy|move]

Environment fallback:
  INCUS_OP_ACTION=snapshot|backup|restore|migrate
  INCUS_OP_INSTANCE=name
  INCUS_OP_SNAPSHOT=name
  INCUS_OP_ARCHIVE=/path/to/backup.tar.gz
  INCUS_OP_REMOTE=remote
  INCUS_OP_TARGET=name
  INCUS_OP_MODE=copy|move
  INCUS_OP_REFRESH=true
EOF
}

require_incus() {
    if ! command -v incus >/dev/null 2>&1; then
        red "Incus command not found."
        red "未找到 incus 命令。"
        exit 1
    fi
}

require_value() {
    local value="$1"
    local name="$2"
    if [ -z "$value" ]; then
        red "Missing required value: $name"
        red "缺少必要参数：$name"
        usage
        exit 1
    fi
}

timestamp() {
    date +%Y%m%d%H%M%S
}

is_truthy() {
    case "${1:-}" in
    true | TRUE | True | 1 | yes | YES | Yes | y | Y) return 0 ;;
    esac
    return 1
}

snapshot_instance() {
    local instance="$1"
    local snapshot="${2:-}"
    require_value "$instance" "INSTANCE"
    if [ -z "$snapshot" ]; then
        snapshot="snap-$(timestamp)"
    fi
    incus snapshot "$instance" "$snapshot"
    green "Snapshot created: $instance/$snapshot"
    green "快照已创建：$instance/$snapshot"
}

backup_instance() {
    local instance="$1"
    local archive="${2:-}"
    require_value "$instance" "INSTANCE"
    if [ -z "$archive" ]; then
        archive="${instance}-backup-$(timestamp).tar.gz"
    fi
    mkdir -p "$(dirname "$archive")"
    incus export "$instance" "$archive"
    green "Backup exported: $archive"
    green "备份已导出：$archive"
}

restore_instance() {
    local archive="$1"
    local target="${2:-}"
    require_value "$archive" "ARCHIVE"
    if [ ! -f "$archive" ]; then
        red "Backup archive not found: $archive"
        red "未找到备份文件：$archive"
        exit 1
    fi
    if [ -n "$target" ]; then
        incus import "$archive" "$target"
    else
        incus import "$archive"
    fi
    green "Backup restored"
    green "备份已恢复"
}

migrate_instance() {
    local instance="$1"
    local remote="$2"
    local target="${3:-}"
    local mode="${4:-copy}"
    require_value "$instance" "INSTANCE"
    require_value "$remote" "REMOTE"
    [ -z "$target" ] && target="$instance"
    case "$mode" in
    copy)
        if is_truthy "${INCUS_OP_REFRESH:-}"; then
            incus copy "$instance" "${remote}:${target}" --refresh
        else
            incus copy "$instance" "${remote}:${target}"
        fi
        ;;
    move)
        incus move "$instance" "${remote}:${target}"
        ;;
    *)
        red "Invalid migrate mode: $mode"
        red "迁移模式无效：$mode"
        exit 1
        ;;
    esac
    green "Migration completed: $instance -> ${remote}:${target} ($mode)"
    green "迁移完成：$instance -> ${remote}:${target} ($mode)"
}

main() {
    local action="${1:-${INCUS_OP_ACTION:-}}"
    case "$action" in
    -h | --help | help | "")
        usage
        return 0
        ;;
    esac

    require_incus
    case "$action" in
    snapshot)
        snapshot_instance "${2:-${INCUS_OP_INSTANCE:-}}" "${3:-${INCUS_OP_SNAPSHOT:-}}"
        ;;
    backup)
        backup_instance "${2:-${INCUS_OP_INSTANCE:-}}" "${3:-${INCUS_OP_ARCHIVE:-}}"
        ;;
    restore)
        restore_instance "${2:-${INCUS_OP_ARCHIVE:-}}" "${3:-${INCUS_OP_TARGET:-}}"
        ;;
    migrate)
        migrate_instance "${2:-${INCUS_OP_INSTANCE:-}}" "${3:-${INCUS_OP_REMOTE:-}}" "${4:-${INCUS_OP_TARGET:-}}" "${5:-${INCUS_OP_MODE:-copy}}"
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
