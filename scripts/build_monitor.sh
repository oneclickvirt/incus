#!/bin/bash
# from
# https://github.com/oneclickvirt/incus
# 2023.06.29

# 检查 screen 是否已安装
if ! command -v screen &>/dev/null; then
    if ! apt-get update || ! apt-get install -y screen; then
        echo "Failed to install screen"
        exit 1
    fi
fi

if ! curl -fsSL https://github.com/oneclickvirt/incus/raw/main/scripts/monitor.sh -o monitor.sh; then
    echo "Failed to download monitor.sh"
    exit 1
fi
if ! chmod +x monitor.sh; then
    echo "Failed to make monitor.sh executable"
    exit 1
fi

# 启动一个新的 screen 窗口并在其中运行命令
if ! screen -dmS incus_moniter bash monitor.sh; then
    echo "Failed to start the monitor screen session"
    exit 1
fi
