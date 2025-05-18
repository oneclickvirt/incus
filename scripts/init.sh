#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# cd /root
# ./init.sh NAT服务器前缀 数量
# 2025.05.18

cd /root >/dev/null 2>&1
if [ ! -d "/usr/local/bin" ]; then
  mkdir -p "/usr/local/bin"
fi

check_china() {
  if [[ -z "${CN}" ]]; then
    if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
      echo "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
      CN=true
    fi
  fi
}

setup_directories() {
  cd /root >/dev/null 2>&1
  if [ ! -d "/usr/local/bin" ]; then
    mkdir -p "/usr/local/bin"
  fi
}

create_base_container() {
  local prefix=$1
  incus init images:debian/11 "$prefix" -c limits.cpu=1 -c limits.memory=256MiB
  if [ $? -ne 0 ]; then
    incus init opsmaru:debian/11 "$prefix" -c limits.cpu=1 -c limits.memory=256MiB
  fi
}

configure_storage() {
  local prefix=$1
  if [ -f /usr/local/bin/incus_storage_type ]; then
    storage_type=$(cat /usr/local/bin/incus_storage_type)
  else
    storage_type="btrfs"
  fi
  incus storage create "$prefix" "$storage_type" size=1GB >/dev/null 2>&1
  incus config device override "$prefix" root size=1GB
  incus config device set "$prefix" root limits.max 1GB
  incus config device set "$prefix" root limits.read 500MB
  incus config device set "$prefix" root limits.write 500MB
  incus config device set "$prefix" root limits.read 5000iops
  incus config device set "$prefix" root limits.write 5000iops
}

configure_network() {
  local prefix=$1
  incus config device override "$prefix" eth0 limits.egress=300Mbit
  incus config device override "$prefix" eth0 limits.ingress=300Mbit
  incus config device override "$prefix" eth0 limits.max=300Mbit
}

configure_resources() {
  local prefix=$1
  incus config set "$prefix" limits.cpu.priority 0
  incus config set "$prefix" limits.cpu.allowance 50%
  incus config set "$prefix" limits.cpu.allowance 25ms/100ms
  incus config set "$prefix" limits.memory.swap true
  incus config set "$prefix" limits.memory.swap.priority 1
  incus config set "$prefix" security.nesting true
}

block_ports() {
  local blocked_ports=(3389 8888 54321 65432)
  for port in "${blocked_ports[@]}"; do
    iptables --ipv4 -I FORWARD -o eth0 -p tcp --dport ${port} -j DROP
    iptables --ipv4 -I FORWARD -o eth0 -p udp --dport ${port} -j DROP
  done
}

download_scripts() {
  if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
    curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh
    chmod 777 /usr/local/bin/ssh_bash.sh
    dos2unix /usr/local/bin/ssh_bash.sh
  fi
  cp /usr/local/bin/ssh_bash.sh /root
  if [ ! -f /usr/local/bin/config.sh ]; then
    curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh -o /usr/local/bin/config.sh
    chmod 777 /usr/local/bin/config.sh
    dos2unix /usr/local/bin/config.sh
  fi
  cp /usr/local/bin/config.sh /root
}

configure_china_mirrors() {
  local container_name=$1
  incus exec "$container_name" -- yum install -y curl
  incus exec "$container_name" -- apt-get install curl -y --fix-missing
  incus exec "$container_name" -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
  incus exec "$container_name" -- chmod 777 ChangeMirrors.sh
  incus exec "$container_name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips > /dev/null
  incus exec "$container_name" -- rm -rf ChangeMirrors.sh
}

install_prerequisites() {
  local container_name=$1
  incus exec "$container_name" -- sudo apt-get update -y
  incus exec "$container_name" -- sudo apt-get install curl -y --fix-missing
  incus exec "$container_name" -- sudo apt-get install -y --fix-missing dos2unix
}

setup_ssh() {
  local container_name=$1
  local password=$2
  incus file push /root/ssh_bash.sh "$container_name/root/"
  incus exec "$container_name" -- chmod 777 ssh_bash.sh
  incus exec "$container_name" -- dos2unix ssh_bash.sh
  incus exec "$container_name" -- sudo ./ssh_bash.sh $password
}

setup_config() {
  local container_name=$1
  incus file push /root/config.sh "$container_name/root/"
  incus exec "$container_name" -- chmod +x config.sh
  incus exec "$container_name" -- dos2unix config.sh
  incus exec "$container_name" -- bash config.sh
}

configure_port_forwarding() {
  local container_name=$1
  local ssh_port=$2
  local nat_start=$3
  local nat_end=$4
  incus config device add "$container_name" ssh-port proxy listen=tcp:0.0.0.0:$ssh_port connect=tcp:127.0.0.1:22
  incus config device add "$container_name" nattcp-ports proxy listen=tcp:0.0.0.0:$nat_start-$nat_end connect=tcp:127.0.0.1:$nat_start-$nat_end
  incus config device add "$container_name" natudp-ports proxy listen=udp:0.0.0.0:$nat_start-$nat_end connect=udp:127.0.0.1:$nat_start-$nat_end
}

create_containers() {
  local prefix=$1
  local count=$2
  rm -rf log
  for ((a = 1; a <= count; a++)); do
    local name="$prefix$a"
    local ssh_port=$((20000 + a))
    local nat_start=$((30000 + (a - 1) * 24 + 1))
    local nat_end=$((30000 + a * 24))
    local ori=$(date | md5sum)
    local passwd=${ori:2:9}
    incus copy "$prefix" "$name"
    incus start "$name"
    sleep 1
    if [[ "${CN}" == true ]]; then
      configure_china_mirrors "$name"
    fi
    install_prerequisites "$name"
    setup_ssh "$name" "$passwd"
    setup_config "$name"
    configure_port_forwarding "$name" "$ssh_port" "$nat_start" "$nat_end"
    echo "$name $ssh_port $passwd $nat_start $nat_end" >>log
  done
}

cleanup() {
  rm -rf ssh_bash.sh config.sh ssh_sh.sh
}

main() {
  local prefix=$1
  local count=$2
  setup_directories
  check_china
  create_base_container "$prefix"
  configure_storage "$prefix"
  configure_network "$prefix"
  configure_resources "$prefix"
  block_ports
  download_scripts
  create_containers "$prefix" "$count"
  cleanup
}

main "$1" "$2"
