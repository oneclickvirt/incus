#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2025.08.14

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
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
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
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
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

install_package uidmap

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
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl_path=$(which sysctl)
if [ -f "/etc/sysctl.conf" ]; then
    if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        # 如果被注释，去掉注释
        sed -i 's/^#\?net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        # 没有则追加
        echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf
    fi
fi
SYSCTL_D_CONF="/etc/sysctl.d/99-custom.conf"
mkdir -p /etc/sysctl.d
if ! grep -q "^net.ipv4.ip_forward=1" "$SYSCTL_D_CONF" 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >>"$SYSCTL_D_CONF"
fi
${sysctl_path} --system >/dev/null
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
ufw disable || true
incus remote list
incus remote remove spiritlhl
incus remote add spiritlhl https://incusimages.spiritlhl.net --protocol simplestreams --public
incus image list spiritlhl:debian
incus remote list
