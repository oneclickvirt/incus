#!/bin/bash
# by https://github.com/oneclickvirt/incus
# 2023.09.05

# 服务管理兼容性函数：支持systemd、OpenRC和传统service命令
# 在混合环境中会尝试多个命令以确保操作成功
service_manager() {
    local action=$1
    local service_name=$2
    local executed=false
    local success=false
    
    case "$action" in
        enable)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl enable "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-update >/dev/null 2>&1; then
                if rc-update add "$service_name" default 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v chkconfig >/dev/null 2>&1; then
                if chkconfig "$service_name" on 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            ;;
        start)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl start "$service_name" 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if command -v rc-service >/dev/null 2>&1; then
                if rc-service "$service_name" start 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                if service "$service_name" start 2>/dev/null; then
                    executed=true
                    success=true
                fi
            fi
            ;;
    esac
    
    if $executed; then
        return 0
    else
        return 1
    fi
}

# 环境安装
# 安装vnstat
apt update
apt install wget sudo curl -y
# apt install linux-headers-$(uname -r) -y
# wget https://github.com/vergoh/vnstat/releases/download/v2.10/vnstat-2.10.tar.gz
# # gd gd-devel
# apt install build-essential libsqlite3-dev -y
# tar -xvf vnstat-2.10.tar.gz
# cd vnstat-2.10/
# sudo ./configure --prefix=/usr --sysconfdir=/etc
# sudo make
# sudo make install
# cp -v examples/systemd/vnstat.service /etc/systemd/system/
# systemctl enable vnstat
# systemctl start vnstat
# cp -v examples/init.d/redhat/vnstat /etc/init.d/
# sudo sed -i '/deb http:\/\/archive.ubuntu.com\/ubuntu\/ trusty main universe restricted multiverse/d' /etc/apt/sources.list
# grep -q "deb http://archive.ubuntu.com/ubuntu/ trusty main universe restricted multiverse" /etc/apt/sources.list || echo "deb http://archive.ubuntu.com/ubuntu/ trusty main universe restricted multiverse" >>/etc/apt/sources.list
# apt install chkconfig -y
# if [ $? -ne 0 ]; then
#     apt install sysv-rc-conf -y
#     if [ $? -ne 0 ]; then
#         apt update && apt install sysv-rc-conf -y
#     fi
# fi
# ! chkconfig vnstat on && echo "replace chkconfig with sysv-rc-conf" && sysv-rc-conf vnstat on
# service vnstat start
# vnstat -v
# vnstatd -v
# ! vnstati -v && echo "vnstat 编译安装无vnstati工具，如需使用请使用命令 apt install vnstati -y 覆盖安装apt源版本"
apt install make -y
apt install gcc -y
apt install libc6-dev -y
apt install libsqlite3-0 -y
apt install libsqlite3-dev -y
apt install libgd3 -y
apt install libgd-dev -y
cd /usr/src
wget https://humdi.net/vnstat/vnstat-2.11.tar.gz
chmod 777 vnstat-2.11.tar.gz
tar zxvf vnstat-2.11.tar.gz
cd vnstat-2.11
./configure --prefix=/usr --sysconfdir=/etc && make && make install
cp -v examples/systemd/vnstat.service /etc/systemd/system/
service_manager enable vnstat
service_manager start vnstat
pgrep -c vnstatd
vnstat -v
vnstatd -v
vnstati -v

