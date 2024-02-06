#!/bin/sh
# by https://github.com/oneclickvirt/incus
# 2024.02.26

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be executed with root privileges."
  exit 1
fi
if [ "$(cat /etc/os-release | grep -E '^ID=' | cut -d '=' -f 2 | tr -d '"')" == "alpine" ]; then
  apk update
  apk add --no-cache openssh-server
  apk add --no-cache sshpass
  apk add --no-cache openssh-keygen
  apk add --no-cache bash
  apk add --no-cache curl
  apk add --no-cache wget
  apk add --no-cache cronie
  apk add --no-cache cron
  cd /etc/ssh
  ssh-keygen -A
  chattr -i /etc/ssh/sshd_config
  sed -i '/^#PermitRootLogin\|PermitRootLogin/c PermitRootLogin yes' /etc/ssh/sshd_config
  sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
  sed -i '/^#ListenAddress\|ListenAddress/c ListenAddress 0.0.0.0' /etc/ssh/sshd_config
  sed -i '/^#AddressFamily\|AddressFamily/c AddressFamily any' /etc/ssh/sshd_config
  sed -i "s/^#\?\(Port\).*/\1 22/" /etc/ssh/sshd_config
  sed -i -E 's/^#?(Port).*/\1 22/' /etc/ssh/sshd_config
  sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config
  sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
  sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
  sed -E -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
  /usr/sbin/sshd
  rc-update add sshd default
  echo root:"$1" | chpasswd root
  chattr +i /etc/ssh/sshd_config
elif [ "$(cat /etc/os-release | grep -E '^ID=' | cut -d '=' -f 2 | tr -d '"')" == "openwrt" ]; then
  opkg update
  opkg install openssh-server
  opkg install bash
  opkg install openssh-keygen
  opkg install shadow-chpasswd
  opkg install chattr
  opkg install cronie
  opkg install cron
  /etc/init.d/sshd enable
  /etc/init.d/sshd start
  cd /etc/ssh
  ssh-keygen -A
  chattr -i /etc/ssh/sshd_config
  sed -i "s/^#\?Port.*/Port 22/g" /etc/ssh/sshd_config
  sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config
  sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
  sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
  sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
  sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
  sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" /etc/ssh/sshd_config
  sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config
  chattr +i /etc/ssh/sshd_config
  echo -e "$1\n$1" | passwd root
  /etc/init.d/sshd restart
fi
/etc/init.d/cron enable || true
/etc/init.d/cron start || true
if [ -f "/etc/motd" ]; then
  echo '' >/etc/motd
  echo 'Related repo https://github.com/oneclickvirt/incus' >>/etc/motd
  echo '--by https://t.me/spiritlhl' >>/etc/motd
fi
if [ -f "/etc/banner" ]; then
  echo '' >/etc/banner
  echo 'Related repo https://github.com/oneclickvirt/incus' >>/etc/banner
  echo '--by https://t.me/spiritlhl' >>/etc/banner
fi
rm -f "$0"
