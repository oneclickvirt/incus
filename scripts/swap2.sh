#!/usr/bin/env bash
# by https://github.com/oneclickvirt/incus
#./swap2.sh 内存大小(以MB计算)
# 2023.06.29

swapsize="$1"

Green="\033[32m"
Font="\033[0m"
Red="\033[31m"

default_swap_size() {
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
    if [[ "$mem_mb" =~ ^[1-9][0-9]*$ ]]; then
        echo $((mem_mb * 2))
    else
        echo 1024
    fi
}

validate_swap_size() {
    if [ -z "$swapsize" ]; then
        swapsize="${SWAP_SIZE:-$(default_swap_size)}"
    fi
    if ! [[ "$swapsize" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${Red}Invalid swap size, please use a positive integer in MB.${Font}"
        echo -e "${Red}swap 大小无效，请使用 MB 为单位的正整数。${Font}"
        exit 1
    fi
}

#root权限
root_need() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Red}Error:This script must be run as root!${Font}"
        exit 1
    fi
}

#检测ovz
ovz_no() {
    if [[ -d "/proc/vz" ]]; then
        echo -e "${Red}Your VPS is based on OpenVZ，not supported!${Font}"
        exit 1
    fi
}

add_swap() {
    #swapsize=$(($(cat /proc/meminfo | grep MemTotal | sed "s/[^0-9]*//g")/1024))

    #检查是否存在swapfile
    grep -q "swapfile" /etc/fstab

    #如果不存在将为其创建swap
    if [ $? -ne 0 ]; then
        echo -e "${Green}swapfile未发现，正在为其创建swapfile${Font}"
        validate_swap_size
        fallocate -l "${swapsize}M" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap defaults 0 0' >>/etc/fstab
        echo -e "${Green}swap创建成功，并查看信息：${Font}"
        cat /proc/swaps
        cat /proc/meminfo | grep Swap
    else
        echo -e "${Red}swapfile已存在，swap设置失败，请先运行脚本删除swap后重新设置！${Font}"
    fi
}

del_swap() {
    #检查是否存在swapfile
    grep -q "swapfile" /etc/fstab

    #如果存在就将其移除
    if [ $? -eq 0 ]; then
        echo -e "${Green}swapfile已发现，正在将其移除...${Font}"
        sed -i '/swapfile/d' /etc/fstab
        echo "3" >/proc/sys/vm/drop_caches
        swapoff -a
        rm -f /swapfile
        echo -e "${Green}swap已删除！${Font}"
    else
        echo -e "${Red}swapfile未发现，swap删除失败！${Font}"
    fi
}

#开始菜单
main() {
    root_need
    ovz_no
    echo -e "———————————————————————————————————————"
    echo -e "${Green}Linux VPS一键添加/删除swap脚本${Font}"
    echo -e "${Green}1、添加swap${Font}"
    echo -e "${Green}2、删除swap${Font}"
    echo -e "———————————————————————————————————————"
    del_swap
    sleep 1
    add_swap
}

main
