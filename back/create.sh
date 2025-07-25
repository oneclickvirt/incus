#!/bin/bash
incus init images:"$6" "$1" -c limits.cpu=1 -c limits.memory=1024MiB
incus config device override "$1" root size=10GB
incus config device override "$1" root limits.read 200MB
incus config device override "$1" root.limits.write 200MB
incus config device override "$1" root limits.read 150Iops
incus config device override "$1" root limits.write 150Iops
incus config device override "$1" root limits.cpu.priority 0
incus config device override "$1" root limits.disk.priority 0
incus config device override "$1" root limits.network.priority 0
incus start "$1"
incus exec "$1" -- sudo apt-get install dos2unix curl wget -y
incus exec "$1" -- curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/ssh.sh -o ssh.sh
incus exec "$1" -- dos2unix ssh.sh
incus exec "$1" -- chmod +x ssh.sh
incus exec "$1" -- sudo ./ssh.sh "$2"
incus config device add "$1" ssh-port proxy listen=tcp:0.0.0.0:"$3" connect=tcp:127.0.0.1:22 nat=true
incus config device add "$1" nat-ports proxy listen=tcp:0.0.0.0:"$4"-"$5" connect=tcp:127.0.0.1:5000-5025 nat=true
echo "$2"
rm -rf "$0"
