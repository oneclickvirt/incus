#!/bin/bash

apt update
apt install curl wget sudo dos2unix ufw -y
ufw disable
wget https://raw.githubusercontent.com/oneclickvirt/incus/main/swap.sh
chmod 777 swap.sh
sudo ./swap.sh
apt install snapd -y
snap install lxd
/snap/bin/lxd init
# incus -h
# 无lxc命令
# vim /root/.bashrc
# alias lxc="/snap/bin/lxc"
# source /root/.bashrc
# 初始化
rm -rf init.sh
wget https://github.com/oneclickvirt/incus/raw/main/init.sh
chmod 777 init.sh
apt install dos2unix -y
dos2unix init.sh
