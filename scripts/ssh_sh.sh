#!/bin/sh
# by https://github.com/oneclickvirt/incus
# 2024.05.13

# 检测 sed 是否支持 -E 选项
check_sed_extended_regex() {
    if echo "test" | sed -E 's/test/passed/' >/dev/null 2>&1; then
        SED_EXTENDED="-E"
    else
        SED_EXTENDED="-r"
    fi
}

# 检测 grep 是否支持 -E 选项
check_grep_extended_regex() {
    if echo "test" | grep -E 'test' >/dev/null 2>&1; then
        GREP_EXTENDED="-E"
    else
        GREP_EXTENDED=""
    fi
}

# 安全的 sed 替换函数
safe_sed() {
    local pattern="$1"
    local file="$2"
    sed $SED_EXTENDED -i "$pattern" "$file"
}

# 安全的 grep 函数
safe_grep() {
    if [ "$GREP_EXTENDED" = "-E" ]; then
        grep -E "$@"
    else
        grep "$@"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be executed with root privileges."
  exit 1
fi

check_sed_extended_regex
check_grep_extended_regex
config_dir="/etc/ssh/sshd_config.d/"
for file in "$config_dir"*; do
  if [ -f "$file" ] && [ -r "$file" ]; then
    if grep -q "PasswordAuthentication no" "$file"; then
      sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
      echo "File $file updated"
    fi
  fi
done
if [ "$(cat /etc/os-release | safe_grep '^ID=' | cut -d '=' -f 2 | tr -d '"')" == "alpine" ]; then
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
  sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
  sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
  sed -i '/^#AddressFamily\|AddressFamily/c AddressFamily any' /etc/ssh/sshd_config
  sed -i "s/^#\?\(Port\).*/\1 22/" /etc/ssh/sshd_config
  check_sed_extended_regex
  safe_sed 's/^#?(Port).*/\1 22/' /etc/ssh/sshd_config
  sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config
  if [ -f "/etc/cloud/cloud.cfg" ]; then
    safe_sed 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    safe_sed 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
    safe_sed 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
  fi
  /usr/sbin/sshd
  rc-update add sshd default
  echo root:"$1" | chpasswd root
  chattr +i /etc/ssh/sshd_config
elif [ "$(cat /etc/os-release | safe_grep '^ID=' | cut -d '=' -f 2 | tr -d '"')" == "openwrt" ]; then
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
