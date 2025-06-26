#!/bin/bash

# 检查 Docker 服务是否运行
if ! systemctl is-active --quiet docker; then
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