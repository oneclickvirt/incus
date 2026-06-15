#!/bin/bash
# from https://github.com/oneclickvirt/incus
# 2023.06.29

divert_install_script() {
  local package_name=$1
  local divert_script="/usr/local/sbin/${package_name}-install"
  local install_script=""
  mkdir -p /usr/local/sbin
  if command -v dpkg >/dev/null 2>&1; then
    install_script="/var/lib/dpkg/info/${package_name}.postinst"
  elif command -v rpm >/dev/null 2>&1; then
    install_script="/usr/lib/rpm/${package_name}.postinst"
  fi
  if [ -n "$install_script" ] && [ -d "$(dirname "$install_script")" ]; then
    ln -sf "${divert_script}" "${install_script}" 2>/dev/null || true
  fi
  echo '#!/bin/bash' >"${divert_script}"
  echo 'exit 1' >>"${divert_script}"
  chmod +x "${divert_script}"
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

append_as_root() {
  local target="$1"
  if [ "$(id -u)" -eq 0 ]; then
    cat >>"$target"
  else
    sudo tee -a "$target" >/dev/null
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  echo "Package: zmap nmap masscan medusa apache2-utils hping3
Pin: release *
Pin-Priority: -1" | append_as_root /etc/apt/preferences
fi

if command -v apt-get >/dev/null 2>&1; then
  run_as_root apt-get update
elif command -v yum >/dev/null 2>&1; then
  run_as_root yum update
elif command -v apk >/dev/null 2>&1; then
  run_as_root apk update
elif command -v pacman >/dev/null 2>&1; then
  run_as_root pacman -Sy
fi

divert_install_script "zmap"
divert_install_script "nmap"
divert_install_script "masscan"
divert_install_script "medusa"
divert_install_script "hping3"
divert_install_script "apache2-utils"
rm -rf "$0"
