#!/bin/bash

# 服务管理兼容性函数：支持systemd、OpenRC和传统service命令
# 在混合环境中会尝试多个命令以确保操作成功
service_manager() {
    local action=$1
    local service_name=$2
    
    case "$action" in
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
}

# 检查 Docker 服务是否运行
if ! service_manager is-active docker; then
    exit 0
fi
# 检查规则是否存在
if ! iptables -C DOCKER-USER -j ACCEPT > /dev/null 2>&1; then
    # 添加接受所有规则
    iptables -I DOCKER-USER -j ACCEPT
else
    # 规则已存在，确保它在最前面的位置
    RULE_POSITION=$(iptables -L DOCKER-USER --line-numbers | grep "ACCEPT all" | head -1 | awk '{print $1}')
    if [ -n "$RULE_POSITION" ] && [ "$RULE_POSITION" -gt 1 ]; then
        # 删除旧规则
        iptables -D DOCKER-USER "$RULE_POSITION"
        # 重新插入到顶部
        iptables -I DOCKER-USER -j ACCEPT
    fi
fi