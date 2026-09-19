#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/incus
# 2025.08.03

# 输入
# ./modify.sh 服务器名称 SSH端口 外网起端口 外网止端口 下载速度 上传速度 是否启用IPV6(Y or N)
# 如果 外网起端口 外网止端口 都设置为0则不做区间外网端口映射了，只映射基础的SSH端口，注意不能为空，不进行映射需要设置为0

# 创建容器
cd /root >/dev/null 2>&1 || exit 1
name="${1:-test}"
sshn="${2:-20001}"
nat1="${3:-20002}"
nat2="${4:-20025}"
in="${5:-300}"
out="${6:-300}"

detect_container_system() {
    incus exec "$name" -- sh -c '
        if [ -r /etc/os-release ]; then
            . /etc/os-release
            printf "%s %s %s\n" "${ID:-}" "${ID_LIKE:-}" "${NAME:-}"
        elif [ -r /etc/openwrt_release ]; then
            echo openwrt
        else
            uname -s
        fi
    ' 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

ensure_container_ipv6_cron() {
    incus exec "$name" -- /bin/sh -c 'set -eu; if [ -L /etc/cron.d ]; then exit 1; fi; [ -d /etc/cron.d ] || exit 0; mkdir -p /run/lock; test ! -L /run/lock; lock=/run/lock/oneclickvirt-ipv6.lock.d; acquired=0; i=0; while [ "$i" -lt 100 ]; do if mkdir "$lock" 2>/dev/null; then acquired=1; break; fi; i=$((i + 1)); sleep 0.1; done; [ "$acquired" -eq 1 ]; trap '\''rmdir "$lock" 2>/dev/null || true'\'' EXIT; target=/etc/cron.d/oneclickvirt-ipv6; line="*/1 * * * * root curl --noproxy '\''*'\'' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb >/dev/null 2>&1 && curl --noproxy '\''*'\'' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb >/dev/null 2>&1"; if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then exit 1; fi; if [ -f "$target" ] && grep -Fqx "$line" "$target"; then exit 0; fi; tmp=$(mktemp /etc/cron.d/.oneclickvirt-ipv6.XXXXXX); trap '\''rm -f -- "$tmp"; rmdir "$lock" 2>/dev/null || true'\'' EXIT; if [ -f "$target" ]; then cat "$target" >"$tmp"; last=$(tail -c 1 "$target" 2>/dev/null | od -An -t x1 | tr -d "[:space:]"); [ -z "$last" ] || [ "$last" = 0a ] || printf "\n" >>"$tmp"; fi; printf "%s\n" "$line" >>"$tmp"; chmod 0644 "$tmp"; mv -f "$tmp" "$target"'
}

generate_password() {
    local generated=""
    if command -v openssl >/dev/null 2>&1; then
        generated="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)"
    fi
    if [ -z "$generated" ] && [ -r /dev/urandom ]; then
        generated="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    fi
    if [ -z "$generated" ]; then
        generated="$(date +%s%N 2>/dev/null | sha256sum | cut -c 1-16)"
    fi
    echo "$generated"
}

# 支持docker虚拟化
incus config set "$name" security.nesting true
passwd="$(generate_password)"
incus start "$name"
sleep 1
/usr/local/bin/check-dns.sh
system="$(detect_container_system)"
if echo "$system" | grep -qiE "centos" || echo "$system" | grep -qiE "almalinux" || echo "$system" | grep -qiE "fedora" || echo "$system" | grep -qiE "rocky"; then
    incus exec "$name" -- yum update -y
    incus exec "$name" -- yum install -y curl
    incus exec "$name" -- yum install -y dos2unix
elif echo "$system" | grep -qiE "alpine"; then
    incus exec "$name" -- apk update
    incus exec "$name" -- apk add --no-cache curl
elif echo "$system" | grep -qiE "arch|archlinux"; then
    incus exec "$name" -- pacman -Sy
    incus exec "$name" -- pacman -Sy --noconfirm --needed curl
    incus exec "$name" -- pacman -Sy --noconfirm --needed dos2unix
elif echo "$system" | grep -qiE "openwrt"; then
    incus exec "$name" -- opkg update
else
    incus exec "$name" -- apt-get update -y
    incus exec "$name" -- apt-get install curl -y --fix-missing
    incus exec "$name" -- apt-get install dos2unix -y --fix-missing
fi
if echo "$system" | grep -qiE "alpine" || echo "$system" | grep -qiE "openwrt"; then
    if [ ! -f /usr/local/bin/ssh_sh.sh ]; then
        curl -fsSLk https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_sh.sh -o /usr/local/bin/ssh_sh.sh || exit 1
        chmod 755 /usr/local/bin/ssh_sh.sh
        dos2unix /usr/local/bin/ssh_sh.sh
    fi
    cp /usr/local/bin/ssh_sh.sh /root
    incus file push /root/ssh_sh.sh "$name"/root/
    incus exec "$name" -- chmod 755 ssh_sh.sh
    incus exec "$name" -- ./ssh_sh.sh "$passwd"
else
    if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
        curl -fsSLk https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh || exit 1
        chmod 755 /usr/local/bin/ssh_bash.sh
        dos2unix /usr/local/bin/ssh_bash.sh
    fi
    cp /usr/local/bin/ssh_bash.sh /root
    incus file push /root/ssh_bash.sh "$name"/root/
    incus exec "$name" -- chmod 755 ssh_bash.sh
    incus exec "$name" -- dos2unix ssh_bash.sh
    incus exec "$name" -- ./ssh_bash.sh "$passwd"
    if [ ! -f /usr/local/bin/config.sh ]; then
        curl -fsSLk https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/config.sh -o /usr/local/bin/config.sh || exit 1
        chmod 755 /usr/local/bin/config.sh
        dos2unix /usr/local/bin/config.sh
    fi
    cp /usr/local/bin/config.sh /root
    incus file push /root/config.sh "$name"/root/
    incus exec "$name" -- chmod +x config.sh
    incus exec "$name" -- dos2unix config.sh
    incus exec "$name" -- bash config.sh
    # `history` is a Bash builtin; Incus exec needs a shell boundary.
    incus exec "$name" -- bash -c 'history -c'
fi
incus restart "$name"
echo "Waiting for the container to start. Attempting to retrieve the container's IP address..."
max_retries=3
delay=5
for ((i=1; i<=max_retries; i++)); do
    echo "Attempt $i: Waiting $delay seconds before retrieving container info..."
    sleep $delay
    container_ip=$(incus list "$name" --format json | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet") | .address')
    if [[ -n "$container_ip" ]]; then
        echo "Container IPv4 address: $container_ip"
        break
    fi
    delay=$((delay * 2))
done
if [[ -z "$container_ip" ]]; then
    echo "Error: Container failed to start or no IP address was assigned."
    exit 1
fi
ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p' | cut -d/ -f1)
echo "Host IPv4 address: $ipv4_address"
# 是否要创建V6地址
if [ -n "$7" ]; then
    if [[ "$7" =~ ^[Yy]$ ]]; then
        ensure_container_ipv6_cron || exit 1
        sleep 1
        if [ ! -f "./build_ipv6_network.sh" ]; then
            # 如果不存在，则从指定 URL 下载并添加可执行权限
            curl -fsSLk https://raw.githubusercontent.com/oneclickvirt/incus/main/scripts/build_ipv6_network.sh -o build_ipv6_network.sh && chmod +x build_ipv6_network.sh || exit 1
        fi
        ./build_ipv6_network.sh "$name"
    fi
fi
# 网速
incus stop "$name"
if ((in == out)); then
    speed_limit="$in"
else
    speed_limit=$(($in > $out ? $in : $out))
fi
# 上传 下载 最大
incus config device override "$name" eth0 limits.egress="$out"Mbit limits.ingress="$in"Mbit limits.max="$speed_limit"Mbit
if ! incus config device set "$name" eth0 ipv4.address "$container_ip" 2>/dev/null; then
    incus config device override "$name" eth0 ipv4.address="$container_ip"
fi
incus config device add "$name" ssh-port proxy listen=tcp:$ipv4_address:$sshn connect=tcp:0.0.0.0:22 nat=true
if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
    incus config device add "$name" nattcp-ports proxy listen=tcp:$ipv4_address:$nat1-$nat2 connect=tcp:0.0.0.0:$nat1-$nat2 nat=true
    incus config device add "$name" natudp-ports proxy listen=udp:$ipv4_address:$nat1-$nat2 connect=udp:0.0.0.0:$nat1-$nat2 nat=true
fi
incus start "$name"
rm -rf ssh_bash.sh config.sh ssh_sh.sh
if echo "$system" | grep -qiE "alpine"; then
    sleep 3
    incus stop "$name"
    incus start "$name"
fi
if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
    echo "$name $sshn $passwd $nat1 $nat2" >"$name"
    echo "$name $sshn $passwd $nat1 $nat2"
    exit 0
fi
if [ "$nat1" == "0" ] && [ "$nat2" == "0" ]; then
    echo "$name $sshn $passwd" >"$name"
    echo "$name $sshn $passwd"
fi
