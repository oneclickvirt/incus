#!/bin/bash
incus init images:ubuntu/20.04 "$1" -c limits.cpu=1 -c limits.memory=1024MiB
incus config device override "$1" root size=10GB
incus config device set "$1" root limits.read 100MB
incus config device set "$1" root limits.write 100MB
incus config device set "$1" root limits.read 150iops
incus config device set "$1" root limits.write 100iops
incus config set "$1" limits.cpu.priority 0
incus config set "$1" limits.network.priority 0
incus config set "$1" limits.memory.swap false
incus start "$1"
incus exec "$1" -- sudo apt-get install dos2unix curl -y
incus exec "$1" -- curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/ssh.sh -o ssh.sh
incus exec "$1" -- dos2unix ssh.sh
incus exec "$1" -- chmod +x ssh.sh
incus exec "$1" -- sudo ./ssh.sh "$2"
incus config device add "$1" ssh-port proxy listen=tcp:0.0.0.0:"$3" connect=tcp:127.0.0.1:22
incus config device add "$1" nat-ports proxy listen=tcp:0.0.0.0:"$4"-"$5" connect=tcp:127.0.0.1:5000-5025
echo "$2"
rm -rf "$0"
