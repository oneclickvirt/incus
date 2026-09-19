#!/usr/bin/env bash
# Actual nftables and both xtables backends in isolated Linux namespaces.
# Only runtime configuration reads are stubbed; every packet and firewall
# operation uses the kernel. This is not public IPv6 acceptance.
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 75; }
[ "$EUID" -eq 0 ] || skip 'real firewall test requires root with network/mount namespace privileges'
for tool in unshare ip nft iptables-nft iptables-legacy python3; do
    command -v "$tool" >/dev/null || skip "real firewall test requires $tool"
done
if [ "${1:-}" != --inside ]; then
    unshare --mount --net true >/dev/null 2>&1 || skip 'real firewall test requires mount and network namespace privileges'
    exec unshare --mount --net env OCV_NAT_OUTER_NS="$(readlink /proc/self/ns/net)" bash "$0" --inside
fi
[ -n "${OCV_NAT_OUTER_NS:-}" ] && [ "$OCV_NAT_OUTER_NS" != "$(readlink /proc/self/ns/net)" ] ||
    fail 'refusing firewall tests in the caller network namespace'
mount --make-rprivate /
# Hide host namespace handles too; no test name may refer to a host namespace.
mount -t tmpfs tmpfs /run
mkdir -p /run/netns
if [ -d /etc/firewalld ]; then
    mount -t tmpfs tmpfs /etc/firewalld
    printf '%s\n' 'FirewallBackend=nftables' 'DefaultZone=public' > /etc/firewalld/firewalld.conf
fi
unset DBUS_SYSTEM_BUS_ADDRESS
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [ -f "$repo_root/scripts/incus_install.sh" ]; then
    runtime=incus
    installer="$repo_root/scripts/incus_install.sh"
    uninstaller="$repo_root/scripts/uninstall_incus.sh"
    table=incus_masq
    chain=postrouting
else
    runtime=lxd
    installer="$repo_root/scripts/lxdinstall.sh"
    uninstaller="$repo_root/scripts/lxduninstall.sh"
    table=lxd_nat
    chain=postrouting_masq
fi
bridge="${runtime}br0"
load_function() {
    local definition
    definition=$(awk -v name="$2" '$0==name "() {" { active=1 } active {print} active && /^}$/ {exit}' "$1")
    [ -n "$definition" ] || fail "missing function $2"
    # Read runtime metadata from a fixture; do not replace nft/iptables.
    eval "${definition//\/snap\/bin\/lxc/lxc}"
}
load_function "$installer" configure_nft_masquerade
load_function "$installer" "sync_${runtime}_firewalld_masquerade"
load_function "$installer" configure_firewalld_masquerade
load_function "$installer" "remove_${runtime}_iptables_masquerade"
load_function "$installer" "remove_${runtime}_iptables_persistence"
load_function "$installer" "retire_${runtime}_iptables_masquerade"
load_function "$installer" add_iptables_masq_once
mock_nat_enabled=true
mock_subnet=10.78.1.1/24
network_query() {
    case "$*" in
        "network get $bridge ipv4.nat") printf '%s\n' "$mock_nat_enabled" ;;
        "network get $bridge ipv4.address") printf '%s\n' "$mock_subnet" ;;
        *) fail "unexpected runtime operation: $*" ;;
    esac
}
incus() { network_query "$@"; }
lxc() { network_query "$@"; }
test_dir=$(mktemp -d)
server_pid=""
firewalld_pid=""
dbus_pid=""
cleanup() {
    for daemon_pid in "$firewalld_pid" "$dbus_pid"; do
        [ -z "$daemon_pid" ] || kill "$daemon_pid" 2>/dev/null || true
    done
    [ -z "$firewalld_pid" ] || wait "$firewalld_pid" 2>/dev/null || true
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT
if command -v firewall-cmd >/dev/null 2>&1; then
    command -v dbus-daemon >/dev/null || fail 'firewalld isolation requires dbus-daemon'
    mkdir -p /run/dbus
    dbus_pid=$(dbus-daemon --system --fork --nopidfile --print-pid)
fi
sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.all.forwarding=1
for namespace in guest other outside; do
    ip netns add "$namespace"
    ip -n "$namespace" link set lo up
    ip netns exec "$namespace" sysctl -qw net.ipv6.conf.all.disable_ipv6=0
done
make_link() {
    local interface="$1" namespace="$2" v4="$3" v6="$4"
    ip link add "$interface" type veth peer name eth0 netns "$namespace"
    ip addr add "$v4.1/24" dev "$interface"
    ip -6 addr add "$v6::1/64" dev "$interface" nodad
    ip link set "$interface" up
    ip -n "$namespace" addr add "$v4.2/24" dev eth0
    ip -n "$namespace" -6 addr add "$v6::2/64" dev eth0 nodad
    ip -n "$namespace" link set eth0 up
    ip -n "$namespace" route add default via "$v4.1"
    ip -n "$namespace" -6 route add default via "$v6::1"
}
make_link "$bridge" guest 10.78.1 fd75:1
make_link otherbr0 other 10.78.2 fd75:2
make_link uplink outside 192.0.2 fd75:3
ip netns exec outside python3 -u -c '
import select, socket
sockets=[]
for family, address in ((socket.AF_INET, "192.0.2.2"), (socket.AF_INET6, "fd75:3::2")):
    sock=socket.socket(family, socket.SOCK_DGRAM)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind((address, 18080))
    sockets.append(sock)
print("ready", flush=True)
while True:
    for sock in select.select(sockets, [], [], 10)[0]:
        data, peer=sock.recvfrom(1024)
        sock.sendto(peer[0].encode(), peer)
' >"$test_dir/server.log" 2>&1 &
server_pid=$!
for _attempt in {1..100}; do
    grep -Fxq ready "$test_dir/server.log" && break
    kill -0 "$server_pid" 2>/dev/null || fail 'packet receiver failed'
    sleep 0.05
done
grep -Fxq ready "$test_dir/server.log" || fail 'receiver readiness deadline'
client_port=24000
check_packet() {
    local namespace="$1" family="$2" expected="$3" actual
    client_port=$((client_port + 1))
    actual=$(ip netns exec "$namespace" python3 - "$family" "$client_port" <<'PY'
import socket, sys
family=socket.AF_INET if sys.argv[1] == "4" else socket.AF_INET6
with socket.socket(family, socket.SOCK_DGRAM) as sock:
    sock.settimeout(4)
    sock.bind(("0.0.0.0" if family == socket.AF_INET else "::", int(sys.argv[2])))
    sock.sendto(b"source identity", ("192.0.2.2" if family == socket.AF_INET else "fd75:3::2", 18080))
    print(sock.recv(1024).decode())
PY
    ) || fail "packet failed: $namespace IPv$family"
    [ "$actual" = "$expected" ] || fail "$namespace IPv$family source: expected $expected, got $actual"
}
check_scoped_traffic() {
    check_packet guest 4 192.0.2.1
    check_packet guest 6 fd75:1::2
    check_packet other 4 10.78.2.2
    check_packet other 6 fd75:2::2
}
# Reproduce the old failure first so an IPv6-disabled host cannot pass.
nft add table inet "$table"
nft "add chain inet $table $chain { type nat hook postrouting priority srcnat; policy accept; }"
nft add rule inet "$table" "$chain" masquerade
check_packet guest 6 fd75:3::1
check_packet other 4 192.0.2.1
configure_nft_masquerade "$test_dir/rules.v4"
check_scoped_traffic
configure_nft_masquerade "$test_dir/rules.v4"
check_scoped_traffic
mock_nat_enabled=false
configure_nft_masquerade "$test_dir/rules.v4"
check_packet guest 4 10.78.1.2
check_packet guest 6 fd75:1::2
# Switching to nftables must also retire tagged rules in either xtables
# backend; an empty nft chain alone does not disable old source NAT.
for iptables_binary in iptables-nft iptables-legacy; do
    iptables() { "$iptables_binary" "$@"; }
    mock_nat_enabled=true
    add_iptables_masq_once
    check_packet guest 4 192.0.2.1
    iptables -t nat -A POSTROUTING -s 198.18.0.0/24 -j MASQUERADE
    "$iptables_binary-save" -t nat >"$test_dir/$iptables_binary.rules"
    chmod 640 "$test_dir/$iptables_binary.rules"
    ln -s "$test_dir/$iptables_binary.rules" "$test_dir/rules.v4"
    mock_nat_enabled=false
    configure_nft_masquerade "$test_dir/rules.v4"
    check_packet guest 4 10.78.1.2
    check_packet guest 6 fd75:1::2
    [ -L "$test_dir/rules.v4" ] || fail 'migration replaced the policy symlink'
    [ "$(stat -c %a "$test_dir/rules.v4")" = 777 ] || fail 'unexpected symlink mode'
    [ "$(stat -c %a "$test_dir/$iptables_binary.rules")" = 640 ] || fail 'migration changed saved policy permissions'
    if grep -Fq "oneclickvirt-$runtime-ipv4" "$test_dir/rules.v4"; then fail 'persistent NAT survived migration'; fi
    grep -Fxq -- '-A POSTROUTING -s 198.18.0.0/24 -j MASQUERADE' "$test_dir/rules.v4" || fail 'migration removed foreign saved policy'
    iptables -t nat -C POSTROUTING -s 198.18.0.0/24 -j MASQUERADE || fail 'migration removed foreign live policy'
    iptables -t nat -D POSTROUTING -s 198.18.0.0/24 -j MASQUERADE
    rm -- "$test_dir/rules.v4"
done
printf 'PASS: %s xtables-to-nft transition retires both backends and preserves saved policy\n' "$runtime"
unset -f iptables
nft delete table inet "$table"
printf 'PASS: %s nft migration, IPv4 NAT, routed IPv6, unrelated traffic and explicit NAT disablement\n' "$runtime"
for iptables_binary in iptables-nft iptables-legacy; do
    iptables() { "$iptables_binary" "$@"; }
    mock_nat_enabled=true
    add_iptables_masq_once
    check_scoped_traffic
    previous_rules=$(iptables -t nat -S POSTROUTING)
    for mock_subnet in 999.78.1.1/24 10.78.1.1/0 10.78.1.1/33; do
        if add_iptables_masq_once; then fail "invalid subnet accepted: $mock_subnet"; fi
        [ "$(iptables -t nat -S POSTROUTING)" = "$previous_rules" ] || fail 'invalid subnet removed working rules'
    done
    mock_subnet=10.78.1.1/24
    add_iptables_masq_once
    [ "$(iptables -t nat -S POSTROUTING | grep -c "oneclickvirt-$runtime-ipv4")" -eq 1 ] || fail 'duplicate NAT rules'
    mock_nat_enabled=false
    add_iptables_masq_once
    check_packet guest 4 10.78.1.2
    mock_nat_enabled=true
    add_iptables_masq_once
    # The uninstaller must remove its tag, preserving a legacy unowned rule
    # and a similarly named administrator tag. Never evaluate saved rule text.
    iptables -t nat -A POSTROUTING -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 198.18.0.0/24 -m comment --comment "oneclickvirt-$runtime-ipv4-custom" -j MASQUERADE
    load_function "$uninstaller" "remove_${runtime}_iptables_masquerade"
    "remove_${runtime}_iptables_masquerade"
    rules=$(iptables -t nat -S POSTROUTING)
    [ "$(printf '%s\n' "$rules" | grep -c '^-A ')" -eq 2 ] || fail 'uninstaller removed unrelated rules or retained its own'
    grep -Fxq -- '-A POSTROUTING -j MASQUERADE' <<<"$rules" || fail 'legacy host-wide rule was removed'
    grep -Fq "oneclickvirt-$runtime-ipv4-custom" <<<"$rules" || fail 'administrator rule was removed'
    iptables -t nat -F POSTROUTING
    printf 'PASS: %s %s traffic, idempotence, NAT disablement and uninstall ownership\n' "$runtime" "$iptables_binary"
done
if [ "${OCV_TEST_FIREWALLD:-false}" = true ]; then
    for tool in firewall-cmd firewall-offline-cmd firewalld dbus-daemon; do
        command -v "$tool" >/dev/null || fail "missing $tool for firewalld acceptance"
    done
    # All daemon state lives in this mount/network namespace, even under sudo.
    start_firewalld() {
        firewalld --nofork --nopid >"$test_dir/firewalld.log" 2>&1 &
        firewalld_pid=$!
        for _attempt in {1..100}; do
            if firewall-cmd --state >/dev/null 2>&1; then return 0; fi
            kill -0 "$firewalld_pid" 2>/dev/null || { cat "$test_dir/firewalld.log"; fail 'firewalld failed'; }
            sleep 0.05
        done
        fail 'firewalld readiness deadline'
    }
    start_firewalld
    unset -f iptables
    for scope in permanent runtime; do
        options=()
        [ "$scope" != permanent ] || options=(--permanent)
        for interface in otherbr0 uplink; do
            firewall-cmd "${options[@]}" --zone=trusted --add-interface="$interface" >/dev/null
        done
        firewall-cmd "${options[@]}" --direct --add-rule ipv4 nat POSTROUTING 0 \
            -s 198.18.0.0/24 -m comment --comment "oneclickvirt-$runtime-ipv4-custom" -j MASQUERADE >/dev/null
    done
    mock_nat_enabled=true
    configure_firewalld_masquerade >/dev/null
    check_scoped_traffic
    configure_firewalld_masquerade >/dev/null
    [ "$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep -c " -o $bridge -m comment --comment oneclickvirt-$runtime-ipv4 -j MASQUERADE$")" -eq 1 ] || fail 'duplicate live firewalld NAT'
    [ "$(firewall-cmd --permanent --direct --get-rules ipv4 nat POSTROUTING | grep -c " -o $bridge -m comment --comment oneclickvirt-$runtime-ipv4 -j MASQUERADE$")" -eq 1 ] || fail 'duplicate saved firewalld NAT'
    for mock_subnet in 999.78.1.1/24 10.78.1.1/0 10.78.1.1/33; do
        if configure_firewalld_masquerade >/dev/null; then fail "firewalld accepted invalid subnet $mock_subnet"; fi
        check_scoped_traffic
    done
    mock_subnet=10.78.1.1/24
    firewall-cmd --reload >/dev/null
    check_scoped_traffic
    mock_nat_enabled=false
    configure_firewalld_masquerade >/dev/null
    check_packet guest 4 10.78.1.2
    check_packet guest 6 fd75:1::2
    firewall-cmd --reload >/dev/null
    check_packet guest 4 10.78.1.2
    mock_nat_enabled=true
    configure_firewalld_masquerade >/dev/null
    configure_nft_masquerade "$test_dir/rules.v4" >/dev/null
    firewall-cmd --reload >/dev/null
    check_scoped_traffic
    if firewall-cmd --permanent --direct --get-rules ipv4 nat POSTROUTING | grep -Fq " -o $bridge "; then fail 'firewalld persistence survived nft migration'; fi
    nft delete table inet "$table"
    configure_firewalld_masquerade >/dev/null
    load_function "$uninstaller" "sync_${runtime}_firewalld_masquerade"
    "sync_${runtime}_firewalld_masquerade" >/dev/null
    check_packet guest 4 10.78.1.2
    configure_firewalld_masquerade >/dev/null
    kill "$firewalld_pid"
    wait "$firewalld_pid"
    firewalld_pid=""
    "sync_${runtime}_firewalld_masquerade" >/dev/null
    start_firewalld
    check_packet guest 4 10.78.1.2
    firewall-cmd --permanent --direct --get-rules ipv4 nat POSTROUTING | grep -Fq "oneclickvirt-$runtime-ipv4-custom" || fail 'foreign saved firewalld rule removed'
    firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep -Fq "oneclickvirt-$runtime-ipv4-custom" || fail 'foreign live firewalld rule removed'
    load_function "$uninstaller" "remove_${runtime}_firewalld_bridge"
    "remove_${runtime}_firewalld_bridge" >/dev/null
    [ "$(firewall-cmd --get-zone-of-interface="$bridge")" = trusted ] || fail 'cleanup detached a surviving bridge'
    ip link delete "$bridge"
    "remove_${runtime}_firewalld_bridge" >/dev/null
    if firewall-cmd --get-zone-of-interface="$bridge" >/dev/null 2>&1; then fail 'deleted bridge retained live trusted assignment'; fi
    if firewall-cmd --permanent --get-zone-of-interface="$bridge" >/dev/null 2>&1; then fail 'deleted bridge retained saved trusted assignment'; fi
    firewall-cmd --permanent --zone=trusted --add-interface="$bridge" >/dev/null
    kill "$firewalld_pid"
    wait "$firewalld_pid"
    firewalld_pid=""
    "remove_${runtime}_firewalld_bridge" >/dev/null
    if firewall-offline-cmd --get-zone-of-interface="$bridge" >/dev/null 2>&1; then fail 'offline cleanup retained deleted bridge'; fi
    start_firewalld
    firewall-cmd --permanent --zone=public --add-interface="$bridge" >/dev/null
    "remove_${runtime}_firewalld_bridge" >/dev/null
    [ "$(firewall-cmd --permanent --get-zone-of-interface="$bridge")" = public ] || fail 'cleanup removed administrator bridge zone'
    printf 'PASS: %s real firewalld NAT, dual-stack isolation, reload, nft migration and active/offline uninstall\n' "$runtime"
fi
