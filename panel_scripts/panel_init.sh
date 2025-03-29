#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2025.02.02

cd /root >/dev/null 2>&1
REGEX=("debian|astra" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "freebsd")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "FreeBSD")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(uname -s)")
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
if [ ! -d "/usr/local/bin" ]; then
    mkdir -p /usr/local/bin
fi
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
export DEBIAN_FRONTEND=noninteractive
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale"
fi

install_package() {
    package_name=$1
    if command -v $package_name >/dev/null 2>&1; then
        _green "$package_name has been installed"
        _green "$package_name 已经安装"
    else
        apt-get install -y $package_name
        if [ $? -ne 0 ]; then
            apt-get install -y $package_name --fix-missing
        fi
        _green "$package_name has attempted to install"
        _green "$package_name 已尝试安装"
    fi
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
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

statistics_of_run_times() {
    COUNT=$(curl -4 -ksm1 "https://hits.spiritlhl.net/incus?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/incus?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
    TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
}

rebuild_cloud_init() {
    if [ -f "/etc/cloud/cloud.cfg" ]; then
        chattr -i /etc/cloud/cloud.cfg
        if grep -q "preserve_hostname: true" "/etc/cloud/cloud.cfg"; then
            :
        else
            sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
            echo "change preserve_hostname to true"
        fi
        if grep -q "disable_root: false" "/etc/cloud/cloud.cfg"; then
            :
        else
            sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
            echo "change disable_root to false"
        fi
        chattr -i /etc/cloud/cloud.cfg
        content=$(cat /etc/cloud/cloud.cfg)
        line_number=$(grep -n "^system_info:" "/etc/cloud/cloud.cfg" | cut -d ':' -f 1)
        if [ -n "$line_number" ]; then
            lines_after_system_info=$(echo "$content" | sed -n "$((line_number + 1)),\$p")
            if [ -n "$lines_after_system_info" ]; then
                updated_content=$(echo "$content" | sed "$((line_number + 1)),\$d")
                echo "$updated_content" >"/etc/cloud/cloud.cfg"
            fi
        fi
        sed -i '/^\s*- set-passwords/s/^/#/' /etc/cloud/cloud.cfg
        chattr +i /etc/cloud/cloud.cfg
    fi
}

install_via_zabbly() {
    echo "使用 Zabbly 仓库安装 incus | Installing incus using Zabbly repository"
    # 创建存放 apt 密钥的目录
    mkdir -p /etc/apt/keyrings/
    # 下载并转换公钥为 gpg 格式
    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
    # 配置 apt 源，引用转换后的公钥文件
    cat <<EOF >/etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.gpg
EOF
    apt update -y
    apt install -y incus
}

$PACKAGETYPE_UPDATE
install_package wget
install_package curl
install_package sudo
install_package dos2unix
install_package ufw
install_package jq
install_package uidmap
install_package ipcalc
install_package unzip
install_package lsb_release
# install_package lxcfs
check_cdn_file
rebuild_cloud_init
$PACKAGETYPE_REMOVE cloud-init
statistics_of_run_times
# 安装incus
if ! command -v incus >/dev/null 2>&1; then
    echo "未检测到 incus，开始自动安装... | incus not found, starting installation..."
    # Alpine Linux 系统
    if [ -f /etc/alpine-release ]; then
        echo "检测到 Alpine Linux | Detected Alpine Linux"
        echo "取消注释 /etc/apk/repositories 中 edge main 与 edge community 仓库 | Uncommenting edge main and edge community repositories in /etc/apk/repositories"
        sed -i 's/^#\s*\(https:\/\/dl-cdn.alpinelinux.org\/alpine\/edge\/main\)/\1/' /etc/apk/repositories
        sed -i 's/^#\s*\(https:\/\/dl-cdn.alpinelinux.org\/alpine\/edge\/community\)/\1/' /etc/apk/repositories
        apk update
        echo "安装 incus 和 incus-client | Installing incus and incus-client"
        apk add incus incus-client
        read -p "是否需要安装虚拟机支持（安装 incus-vm）? [y/N] | Install virtual machine support (install incus-vm)? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            apk add incus-vm
        fi
        echo "添加 incus 服务到系统启动，并启动服务 | Adding incus service to system startup and starting service"
        rc-update add incusd
        rc-service incusd start
    # Debian/Ubuntu 系统
    elif [ -f /etc/debian_version ]; then
        . /etc/os-release
        echo "检测到 $NAME $VERSION_ID | Detected $NAME $VERSION_ID"
        if [[ "$NAME" == "Ubuntu" ]]; then
            if dpkg --compare-versions "$VERSION_ID" ge "24.04"; then
                echo "使用 Ubuntu 原生 incus 包（24.04 LTS 及以上） | Using Ubuntu native incus package (24.04 LTS and later)"
                apt update
                apt install -y incus || install_via_zabbly
            else
                install_via_zabbly
            fi
        else
            if [[ "$VERSION_CODENAME" == "bookworm" ]]; then
                echo "使用 Debian 12 (bookworm) 的 backports 包安装 incus | Installing incus from backports for Debian 12 (bookworm)"
                apt update
                apt install -y incus/bookworm-backports || install_via_zabbly
            else
                echo "使用 Debian 原生 incus 包（适用于 testing/unstable） | Installing native incus package for Debian (testing/unstable)"
                apt update
                apt install -y incus || install_via_zabbly
            fi
        fi
        systemctl enable incus --now
    # Arch Linux 系统
    elif [ -f /etc/arch-release ]; then
        echo "检测到 Arch Linux | Detected Arch Linux"
        echo "移除 iptables（如果存在）并安装 iptables-nft 与 incus | Removing iptables (if exists) and installing iptables-nft and incus"
        pacman -R --noconfirm iptables
        pacman -Syu --noconfirm iptables-nft incus
        systemctl enable incus --now
    # Gentoo 系统
    elif [ -f /etc/gentoo-release ]; then
        echo "检测到 Gentoo | Detected Gentoo"
        echo "使用 emerge 安装 incus | Installing incus using emerge"
        emerge -av app-containers/incus
    # RPM 系统（例如 Rocky Linux）
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        echo "检测到 RPM 系统（如 Rocky Linux） | Detected RPM-based system (e.g., Rocky Linux)"
        echo "安装 epel-release，并启用 COPR 仓库及 CodeReady Builder (CRB) | Installing epel-release, enabling COPR repository and CodeReady Builder (CRB)"
        dnf -y install epel-release
        dnf copr enable -y neil/incus
        dnf config-manager --set-enabled crb
        echo "安装 incus 与 incus-tools | Installing incus and incus-tools"
        dnf install -y incus incus-tools
        systemctl enable incus --now
    # Void Linux 系统
    elif [ -f /etc/void-release ]; then
        echo "检测到 Void Linux | Detected Void Linux"
        echo "使用 xbps 安装 incus 与 incus-client | Installing incus and incus-client using xbps"
        xbps-install -S incus incus-client
        echo "启用并启动 incus 服务 | Enabling and starting incus service"
        ln -s /etc/sv/incus /var/service
        ln -s /etc/sv/incus-user /var/service
        sv up incus
        sv up incus-user
    else
        echo "未识别的系统，尝试使用常见包管理器安装 incus | Unrecognized system, trying common package managers to install incus"
        if command -v apt >/dev/null 2>&1; then
            apt update
            apt install -y incus
            systemctl enable incus --now
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y incus
            systemctl enable incus --now
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Syu --noconfirm incus
            systemctl enable incus --now
        else
            $PACKAGETYPE_INSTALL incus
            if [[ $? -ne 0 ]]; then
                echo "无法识别包管理器，请手动安装 incus | Unable to recognize package manager, please install incus manually."
            else
                systemctl enable incus --now
            fi
        fi
    fi
else
    echo "incus 已经安装 | incus is already installed"
fi

# 读取母鸡配置
while true; do
    _green "How much virtual memory does the host need to open? (Virtual memory SWAP will occupy hard disk space, calculate by yourself, note that it is MB as the unit, need 1G virtual memory then enter 1024):"
    reading "宿主机需要开设多少虚拟内存？(虚拟内存SWAP会占用硬盘空间，自行计算，注意是MB为单位，需要1G虚拟内存则输入1024)：" memory_nums
    if [[ "$memory_nums" =~ ^[1-9][0-9]*$ ]]; then
        break
    else
        _yellow "Invalid input, please enter a positive integer."
        _yellow "输入无效，请输入一个正整数。"
    fi
done
while true; do
    _green "How large a storage pool does the host need to open? (The storage pool is the size of the sum of the ct's hard disk, it is recommended that the SWAP and storage pool add up to 95% of the space of the hen's hard disk, note that it is in GB, enter 10 if you need 10G storage pool):"
    reading "宿主机需要开设多大的存储池？(存储池就是小鸡硬盘之和的大小，推荐SWAP和存储池加起来达到母鸡硬盘的95%空间，注意是GB为单位，需要10G存储池则输入10)：" disk_nums
    if [[ "$disk_nums" =~ ^[1-9][0-9]*$ ]]; then
        break
    else
        _yellow "Invalid input, please enter a positive integer."
        _yellow "输入无效，请输入一个正整数。"
    fi
done

# 资源池设置-硬盘
# incus admin init --storage-backend btrfs --storage-create-loop "$disk_nums" --storage-pool default --auto
# btrfs 检测与安装
temp=$(incus admin init --storage-backend btrfs --storage-create-loop "$disk_nums" --storage-pool default --auto 2>&1)
if [[ $? -ne 0 ]]; then
    status=false
else
    status=true
fi
echo "$temp"
if echo "$temp" | grep -q "incus.migrate" && [[ $status == false ]]; then
    incus.migrate
    temp=$(incus admin init --storage-backend btrfs --storage-create-loop "$disk_nums" --storage-pool default --auto 2>&1)
    if [[ $? -ne 0 ]]; then
        status=false
    else
        status=true
    fi
    echo "$temp"
fi
if [[ $status == false ]]; then
    _yellow "trying to use another storage type ......"
    _yellow "尝试使用其他存储类型......"
    # 类型设置-硬盘
    SUPPORTED_BACKENDS=("zfs" "lvm" "ceph" "dir")
    STORAGE_BACKEND=""
    for backend in "${SUPPORTED_BACKENDS[@]}"; do
        if command -v $backend >/dev/null; then
            STORAGE_BACKEND=$backend
            if [ "$STORAGE_BACKEND" = "dir" ]; then
                if [ ! -f /usr/local/bin/incus_reboot ]; then
                    install_package btrfs-progs
                    _green "Please reboot the machine (perform a reboot reboot) and execute this script again to load the btrfs kernel, after the reboot you will need to enter the configuration you need init again"
                    _green "请重启本机(执行 reboot 重启)再次执行本脚本以加载btrfs内核，重启后需要再次输入你需要的初始化的配置"
                    echo "" >/usr/local/bin/incus_reboot
                    exit 1
                fi
                _green "Infinite storage pool size using default dir type due to no btrfs"
                _green "由于无btrfs，使用默认dir类型无限定存储池大小"
                echo "dir" >/usr/local/bin/incus_storage_type
                incus admin init --storage-backend "$STORAGE_BACKEND" --auto
            else
                _green "Infinite storage pool size using default $backend type due to no btrfs"
                _green "由于无btrfs，使用默认 $backend 类型无限定存储池大小"
                DISK=$(lsblk -p -o NAME,TYPE | awk '$2=="disk"{print $1}')
                incus admin init --storage-backend lvm --storage-create-device $DISK --storage-create-loop "$disk_nums" --storage-pool lvm_pool --auto
            fi
            if [[ $? -ne 0 ]]; then
                _yellow "Use $STORAGE_BACKEND storage type failed."
                _yellow "使用 $STORAGE_BACKEND 存储类型失败。"
            else
                echo $backend >/usr/local/bin/incus_storage_type
                break
            fi
        fi
    done
    if [ -z "$STORAGE_BACKEND" ]; then
        _yellow "No supported storage types, please contact the script maintainer"
        _yellow "无可支持的存储类型，请联系脚本维护者"
        exit 1
    fi
else
    echo "btrfs" >/usr/local/bin/incus_storage_type
fi
install_package uidmap

# 虚拟内存设置
curl -sLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/swap2.sh" -o swap2.sh && chmod +x swap2.sh
./swap2.sh "$memory_nums"
# 设置镜像不更新
incus config unset images.auto_update_interval
incus config set images.auto_update_interval 0
# 增加第三方镜像源
# incus remote add tuna-images https://mirrors.tuna.tsinghua.edu.cn/lxc-images/ --protocol=simplestreams --public>/dev/null 2>&1
incus remote add opsmaru https://images.opsmaru.dev/spaces/43ad54472be82d7236eea3d1 --public --protocol simplestreams >/dev/null 2>&1
# 设置自动配置内网IPV6地址
incus network set incusbr0 ipv6.address auto
# 下载预制文件
files=(
    "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh"
    "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_sh.sh"
    "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh"
    "https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/buildone.sh"
)
for file in "${files[@]}"; do
    filename=$(basename "$file")
    rm -rf "$filename"
    curl -sLk "${cdn_success_url}${file}" -o "$filename"
    chmod 777 "$filename"
    dos2unix "$filename"
done
cp /root/ssh_sh.sh /usr/local/bin
cp /root/ssh_bash.sh /usr/local/bin
cp /root/config.sh /usr/local/bin
sysctl net.ipv4.ip_forward=1
sysctl_path=$(which sysctl)
if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    if grep -q "^#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi
else
    echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf
fi
${sysctl_path} -p
incus network set incusbr0 raw.dnsmasq dhcp-option=6,8.8.8.8,8.8.4.4
incus network set incusbr0 dns.mode managed
# managed none dynamic
incus network set incusbr0 ipv4.dhcp true
incus network set incusbr0 ipv6.dhcp true
# 解除进程数限制
if [ -f "/etc/security/limits.conf" ]; then
    if ! grep -q "*          hard    nproc       unlimited" /etc/security/limits.conf; then
        echo '*          hard    nproc       unlimited' | sudo tee -a /etc/security/limits.conf
    fi
    if ! grep -q "*          soft    nproc       unlimited" /etc/security/limits.conf; then
        echo '*          soft    nproc       unlimited' | sudo tee -a /etc/security/limits.conf
    fi
fi
if [ -f "/etc/systemd/logind.conf" ]; then
    if ! grep -q "UserTasksMax=infinity" /etc/systemd/logind.conf; then
        echo 'UserTasksMax=infinity' | sudo tee -a /etc/systemd/logind.conf
    fi
fi
# 环境安装
# 安装vnstat
install_package make
install_package gcc
install_package libc6-dev
install_package libsqlite3-0
install_package libsqlite3-dev
install_package libgd3
install_package libgd-dev
cd /usr/src
wget https://humdi.net/vnstat/vnstat-2.11.tar.gz
chmod 777 vnstat-2.11.tar.gz
tar zxvf vnstat-2.11.tar.gz
cd vnstat-2.11
./configure --prefix=/usr --sysconfdir=/etc && make && make install
cp -v examples/systemd/vnstat.service /etc/systemd/system/
systemctl enable vnstat
systemctl start vnstat
pgrep -c vnstatd
vnstat -v
vnstatd -v
vnstati -v

# 加装证书
wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/panel_scripts/client.crt -O ~/.config/incus/client.crt
chmod 777 ~/.config/incus/client.crt
# 双确认，部分版本切换了命令
incus config trust add ~/.config/incus/client.crt
incus config trust add-certificate ~/.config/incus/client.crt
incus config set core.https_address :8443

# wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/panel_scripts/client.crt -O /root/snap/lxd/common/config/client.crt
# chmod 777 /root/snap/lxd/common/config/client.crt
# incus config trust add /root/snap/lxd/common/config/client.crt
# incus config set core.https_address :9969

# 加载修改脚本
wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/panel_scripts/modify.sh -O /root/modify.sh
chmod 777 /root/modify.sh
ufw disable
if [ ! -f /usr/local/bin/check-dns.sh ]; then
    wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/check-dns.sh -O /usr/local/bin/check-dns.sh
    chmod +x /usr/local/bin/check-dns.sh
else
    echo "Script already exists. Skipping installation."
fi
if [ ! -f /etc/systemd/system/check-dns.service ]; then
    wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/check-dns.service -O /etc/systemd/system/check-dns.service
    chmod +x /etc/systemd/system/check-dns.service
    systemctl daemon-reload
    systemctl enable check-dns.service
    systemctl start check-dns.service
else
    echo "Service already exists. Skipping installation."
fi
# 加载iptables并设置回源且允许NAT端口转发
install_package iptables
install_package iptables-persistent
iptables -t nat -A POSTROUTING -j MASQUERADE
# 设置IPV4优先
sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf && systemctl restart networking
_green "脚本当天运行次数:${TODAY}，累计运行次数:${TOTAL}"
_green "If you need to turn on more than 100 cts, it is recommended to wait for a few minutes before performing a reboot to reboot the machine to make the settings take effect"
_green "The reboot will ensure that the DNS detection mechanism takes effect, otherwise the batch opening process may cause the host's DNS to be overwritten by the merchant's preset"
_green "如果你需要开启超过100个小鸡，建议等待几分钟后执行 reboot 重启本机以使得设置生效"
_green "重启后可以保证DNS的检测机制生效，否则批量开启过程中可能导致宿主机的DNS被商家预设覆盖，所以最好重启系统一次"
