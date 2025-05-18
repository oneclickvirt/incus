#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# cd /root
# ./least.sh NAT服务器前缀 数量
# 2025.05.18

cd /root >/dev/null 2>&1
if [ ! -d "/usr/local/bin" ]; then
    mkdir -p "/usr/local/bin"
fi

check_china() {
    echo "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            echo "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
            CN=true
        fi
    fi
}

create_base_container() {
    local container_name="$1"
    incus init images:debian/11 "$container_name" -c limits.cpu=1 -c limits.memory=128MiB
    if [ $? -ne 0 ]; then
        incus init opsmaru:debian/11 "$container_name" -c limits.cpu=1 -c limits.memory=128MiB
    fi
}

setup_storage() {
    local container_name="$1"
    if [ -f /usr/local/bin/incus_storage_type ]; then
        storage_type=$(cat /usr/local/bin/incus_storage_type)
    else
        storage_type="btrfs"
    fi
    incus storage create "$container_name" "$storage_type" size=200MB >/dev/null 2>&1
}

configure_resources() {
    local container_name="$1"
    incus config device override "$container_name" root size=200MB
    incus config device set "$container_name" root limits.read 500MB
    incus config device set "$container_name" root limits.write 500MB
    incus config device set "$container_name" root limits.read 5000iops
    incus config device set "$container_name" root limits.write 5000iops
    incus config device set "$container_name" root limits.max 300MB
    incus config device override "$container_name" eth0 limits.egress=300Mbit
    incus config device override "$container_name" eth0 limits.ingress=300Mbit
    incus config device override "$container_name" eth0 limits.max=300Mbit
    incus config set "$container_name" limits.cpu.priority 0
    incus config set "$container_name" limits.cpu.allowance 50%
    incus config set "$container_name" limits.cpu.allowance 25ms/100ms
    incus config set "$container_name" limits.memory.swap true
    incus config set "$container_name" limits.memory.swap.priority 1
    incus config set "$container_name" security.nesting true
}

block_ports() {
    blocked_ports=(3389 8888 54321 65432)
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

setup_container() {
    local name="$1"
    local passwd="$2"
    local sshn="$3"
    incus start "$name"
    sleep 1
    if [[ "${CN}" == true ]]; then
        incus exec "$name" -- yum install -y curl
        incus exec "$name" -- apt-get install curl -y --fix-missing
        incus exec "$name" -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        incus exec "$name" -- chmod 777 ChangeMirrors.sh
        incus exec "$name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips
        incus exec "$name" -- rm -rf ChangeMirrors.sh
    fi
    incus exec "$name" -- sudo apt-get update -y
    incus exec "$name" -- sudo apt-get install curl -y --fix-missing
    incus exec "$name" -- sudo apt-get install -y --fix-missing dos2unix
    incus file push /root/ssh_bash.sh "$name/root/"
    incus exec "$name" -- chmod 777 ssh_bash.sh
    incus exec "$name" -- dos2unix ssh_bash.sh
    incus exec "$name" -- sudo ./ssh_bash.sh $passwd
    incus file push /root/config.sh "$name/root/"
    incus exec "$name" -- chmod +x config.sh
    incus exec "$name" -- dos2unix config.sh
    incus exec "$name" -- bash config.sh
    incus config device add "$name" ssh-port proxy listen=tcp:0.0.0.0:$sshn connect=tcp:127.0.0.1:22
    echo "$name $sshn $passwd" >>log
}

create_containers() {
    local base_name="$1"
    local count="$2"
    for ((a = 1; a <= count; a++)); do
        local container_name="${base_name}${a}"
        local ssh_port=$((20000 + a))
        local ori=$(date | md5sum)
        local password=${ori:2:9}

        incus copy "$base_name" "$container_name"
        setup_container "$container_name" "$password" "$ssh_port"
    done
}

main() {
    local base_name="$1"
    local count="$2"
    rm -rf log
    check_china
    create_base_container "$base_name"
    setup_storage "$base_name"
    configure_resources "$base_name"
    block_ports
    download_scripts
    create_containers "$base_name" "$count"
    rm -rf ssh_bash.sh config.sh ssh_sh.sh
}
main "$1" "$2"
