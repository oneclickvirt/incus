#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2026.03.09
# 卸载 incus 及其所有相关环境 / Uninstall incus and all related environments

cd /root >/dev/null 2>&1

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }

# ==============================
# 权限检查 / Root check
# ==============================
if [[ $EUID -ne 0 ]]; then
    _red "请使用 root 权限运行此脚本！"
    _red "Please run this script as root!"
    exit 1
fi

_yellow "=========================================="
_yellow "  开始卸载 Incus 及所有相关环境"
_yellow "  Uninstalling Incus and all related env"
_yellow "=========================================="

# ==============================
# 停止并销毁所有容器/虚拟机
# Stop and destroy all containers/VMs
# ==============================
_green "[1/9] 停止并销毁所有容器和虚拟机 / Stopping and destroying all containers and VMs..."
if command -v incus >/dev/null 2>&1; then
    for instance in $(incus list -c n --format csv 2>/dev/null); do
        _yellow "  停止并删除 / Stopping and deleting: $instance"
        incus stop "$instance" --force 2>/dev/null || true
        incus delete "$instance" --force 2>/dev/null || true
    done
    # 删除所有镜像 / Delete all images
    for img in $(incus image list --format csv -c f 2>/dev/null | awk -F, '{print $1}'); do
        _yellow "  删除镜像 / Deleting image: $img"
        incus image delete "$img" 2>/dev/null || true
    done
    # 删除所有配置文件 / Delete all profiles (except default)
    for prof in $(incus profile list --format csv 2>/dev/null | awk -F, '{print $1}' | grep -v '^default$'); do
        _yellow "  删除配置文件 / Deleting profile: $prof"
        incus profile delete "$prof" 2>/dev/null || true
    done
fi

# ==============================
# 删除存储池 / Delete storage pools
# ==============================
_green "[2/9] 删除 Incus 存储池 / Deleting Incus storage pools..."
if command -v incus >/dev/null 2>&1; then
    for pool in $(incus storage list --format csv 2>/dev/null | awk -F, '{print $1}'); do
        _yellow "  清理存储卷并删除存储池 / Cleaning volumes and deleting pool: $pool"
        for vol in $(incus storage volume list "$pool" --format csv 2>/dev/null | awk -F, '{print $2}'); do
            incus storage volume delete "$pool" "$vol" 2>/dev/null || true
        done
        incus storage delete "$pool" 2>/dev/null || true
    done
fi

# ==============================
# 删除 incus 网络 / Delete incus networks
# ==============================
_green "[3/9] 删除 Incus 网络 / Deleting Incus networks..."
if command -v incus >/dev/null 2>&1; then
    # 仅删除 incus 自身创建的网桥（名称以 incus 开头，如 incusbr0），跳过物理接口
    # Only delete bridges created by Incus (name starts with "incus"), skip physical interfaces
    for net in $(incus network list --format csv 2>/dev/null | awk -F, '{print $1}' | grep '^incus'); do
        _yellow "  删除网络 / Deleting network: $net"
        incus network delete "$net" 2>/dev/null || true
    done
fi

# ==============================
# 停止并禁用相关系统服务
# Stop and disable related services
# ==============================
_green "[4/9] 停止并禁用相关服务 / Stopping and disabling related services..."
SERVICES=(
    incus-lvm-losetup.service
    incus-zfs-import.service
    check-dns.service
    add-ipv6.service
    coexistence.timer
    coexistence.service
    incus.service
    incusd.service
    incus-startup.service
    incus-user.service
)
for svc in "${SERVICES[@]}"; do
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "${svc%.service}" stop 2>/dev/null || true
        rc-update del "${svc%.service}" default 2>/dev/null || true
    fi
done
if command -v sv >/dev/null 2>&1; then
    sv down incus 2>/dev/null || true
    sv down incus-user 2>/dev/null || true
    rm -f /var/service/incus /var/service/incus-user 2>/dev/null || true
fi

# ==============================
# 清理 LVM / btrfs / ZFS 存储残留
# Clean up LVM / btrfs / ZFS storage remnants
# ==============================
_green "[5/9] 清理存储后端残留 / Cleaning up storage backend remnants..."
STORAGE_DIRS=(/data/incus-storage /var/lib/incus-storage /root/incus-storage)
for storage_dir in "${STORAGE_DIRS[@]}"; do
    # LVM 清理
    if [ -f "$storage_dir/lvm_loop_file.txt" ]; then
        loop_file=$(cat "$storage_dir/lvm_loop_file.txt")
        _yellow "  清理 LVM / Cleaning LVM: $loop_file"
        vgchange -an incus_vg 2>/dev/null || true
        vgremove -f incus_vg 2>/dev/null || true
        loop_dev=$(losetup -j "$loop_file" 2>/dev/null | cut -d: -f1)
        [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null || true
        rm -f "$loop_file" "$storage_dir/lvm_loop_file.txt"
    fi
    # btrfs 清理
    if [ -f "$storage_dir/btrfs_pool.img" ]; then
        mount_point="$storage_dir/btrfs_mount"
        _yellow "  清理 btrfs / Cleaning btrfs: $mount_point"
        umount "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || true
        sed -i "\|$storage_dir/btrfs_pool.img|d" /etc/fstab 2>/dev/null || true
        rm -f "$storage_dir/btrfs_pool.img"
        rm -rf "$mount_point"
    fi
    # ZFS 清理
    if [ -f "$storage_dir/zfs_pool_name.txt" ]; then
        zpool_name=$(cat "$storage_dir/zfs_pool_name.txt")
        _yellow "  清理 ZFS pool / Cleaning ZFS pool: $zpool_name"
        zpool destroy -f "$zpool_name" 2>/dev/null || true
        loop_file=""
        [ -f "$storage_dir/zfs_loop_file.txt" ] && loop_file=$(cat "$storage_dir/zfs_loop_file.txt")
        if [ -n "$loop_file" ]; then
            loop_dev=$(losetup -j "$loop_file" 2>/dev/null | cut -d: -f1)
            [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null || true
            rm -f "$loop_file"
        fi
        rm -f "$storage_dir/zfs_pool_name.txt" "$storage_dir/zfs_loop_file.txt"
    fi
    # 删除整个存储目录
    if [ -d "$storage_dir" ]; then
        _yellow "  删除存储目录 / Removing storage directory: $storage_dir"
        rm -rf "$storage_dir"
    fi
done

# ==============================
# 卸载 incus 软件包
# Uninstall incus packages
# ==============================
_green "[6/9] 卸载 Incus 软件包 / Uninstalling Incus packages..."
if command -v apt >/dev/null 2>&1; then
    apt-get remove --purge -y incus incus-base incus-client incus-extra incus-ui-canonical 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    # 清除 Zabbly 仓库配置
    rm -f /etc/apt/sources.list.d/zabbly-incus-stable.sources
    rm -f /etc/apt/keyrings/zabbly.gpg
    apt-get update -y 2>/dev/null || true
elif command -v dnf >/dev/null 2>&1; then
    dnf remove -y incus incus-tools 2>/dev/null || true
elif command -v yum >/dev/null 2>&1; then
    yum remove -y incus 2>/dev/null || true
elif command -v pacman >/dev/null 2>&1; then
    pacman -Rsc --noconfirm incus iptables-nft 2>/dev/null || true
elif command -v apk >/dev/null 2>&1; then
    apk del incus incus-client 2>/dev/null || true
elif command -v xbps-remove >/dev/null 2>&1; then
    xbps-remove -R incus incus-client 2>/dev/null || true
fi

# ==============================
# 删除服务文件 / Remove service files
# ==============================
_green "[7/9] 删除服务文件 / Removing service files..."
SERVICE_FILES=(
    /etc/systemd/system/incus-lvm-losetup.service
    /etc/systemd/system/incus-zfs-import.service
    /etc/systemd/system/check-dns.service
    /etc/systemd/system/add-ipv6.service
    /etc/systemd/system/coexistence.service
    /etc/systemd/system/coexistence.timer
    /etc/init.d/incus-lvm-losetup
    /etc/init.d/incus-zfs-import
)
for f in "${SERVICE_FILES[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _yellow "  已删除 / Removed: $f"
done
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
fi

# ==============================
# 删除残留脚本和数据文件
# Remove leftover scripts and data files
# ==============================
_green "[8/9] 删除残留文件 / Removing leftover files..."
LEFTOVER_FILES=(
    /usr/local/bin/incus_storage_type
    /usr/local/bin/incus_tried_storage
    /usr/local/bin/incus_installed_storage
    /usr/local/bin/incus_reboot
    /usr/local/bin/check-dns.sh
    /usr/local/bin/add-ipv6.sh
    /usr/local/bin/ssh_bash.sh
    /usr/local/bin/ssh_sh.sh
    /usr/local/bin/config.sh
    /usr/local/bin/buildct.sh
    /usr/local/bin/buildvm.sh
    /usr/local/bin/coexistence.sh
    /usr/local/bin/docker-coexistence.sh
    /usr/local/bin/incus_fixed_restart.sh
    /usr/local/bin/incus_fixed_restart.log
    /usr/local/bin/incus_fixed_restart_counter
    /usr/local/bin/incus_cpulimit.pid
    /usr/local/bin/incus-lvm-restore.sh
    /usr/local/bin/incus-zfs-restore.sh
    /tmp/incus_delete.log
)
for f in "${LEFTOVER_FILES[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _yellow "  已删除 / Removed: $f"
done
# 删除 incrc.local 中的 incus 相关条目
if [ -f /etc/rc.local ]; then
    sed -i '/incus-lvm-restore\.sh/d' /etc/rc.local 2>/dev/null || true
    sed -i '/incus-zfs-restore\.sh/d' /etc/rc.local 2>/dev/null || true
fi
# 删除 incus 数据目录
if [ -d /var/lib/incus ]; then
    _yellow "  删除 Incus 数据目录 / Removing /var/lib/incus"
    # 卸载所有挂载在该目录下的文件系统（从深到浅）
    # Unmount all filesystems under this directory (deepest first)
    while IFS= read -r mount_point; do
        _yellow "  卸载挂载点 / Unmounting: $mount_point"
        umount -l "$mount_point" 2>/dev/null || true
    done < <(mount | awk '{print $3}' | grep '^/var/lib/incus' | sort -r)
    sync
    rm -rf /var/lib/incus
fi
if [ -d /var/cache/incus ]; then
    _yellow "  删除 Incus 缓存目录 / Removing /var/cache/incus"
    rm -rf /var/cache/incus
fi
if [ -d /etc/incus ]; then
    _yellow "  删除 Incus 配置目录 / Removing /etc/incus"
    rm -rf /etc/incus
fi
# 删除 sysctl 相关配置（仅删除由本脚本组添加的条目，不影响其他配置）
if [ -f /etc/sysctl.d/99-custom.conf ]; then
    sed -i '/net\.ipv4\.ip_forward=1/d' /etc/sysctl.d/99-custom.conf 2>/dev/null || true
    [ ! -s /etc/sysctl.d/99-custom.conf ] && rm -f /etc/sysctl.d/99-custom.conf
fi

# ==============================
# 清理 iptables 规则
# Clean up iptables rules
# ==============================
_green "[9/9] 清理 iptables 规则 / Cleaning up iptables rules..."
if command -v iptables >/dev/null 2>&1; then
    # 清理 NAT MASQUERADE
    iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true
    # 清理 incusbr0 相关 FORWARD 规则
    iptables -D FORWARD -i incusbr0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o incusbr0 -j ACCEPT 2>/dev/null || true
    # 清理端口屏蔽规则
    for port in 3389 8888 54321 65432; do
        iptables -D FORWARD -o eth0 -p tcp --dport "$port" -j DROP 2>/dev/null || true
        iptables -D FORWARD -o eth0 -p udp --dport "$port" -j DROP 2>/dev/null || true
    done
    # 保存规则
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -D FORWARD -i incusbr0 -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -o incusbr0 -j ACCEPT 2>/dev/null || true
fi
if command -v ufw >/dev/null 2>&1; then
    ufw delete allow in on incusbr0 2>/dev/null || true
    ufw route delete allow in on incusbr0 2>/dev/null || true
    ufw route delete allow out on incusbr0 2>/dev/null || true
fi

# ==============================
# 完成 / Done
# ==============================
_green "=========================================="
_green "  Incus 卸载完成！"
_green "  Incus uninstallation complete!"
_green "  建议重启服务器以确保所有更改生效。"
_green "  It is recommended to reboot the server"
_green "  to ensure all changes take effect."
_green "=========================================="
