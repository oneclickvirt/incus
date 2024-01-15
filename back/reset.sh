#!/bin/bash
# by https://github.com/oneclickvirt/incus

incus start "$1"
incus exec "$1" -- apt update -y
incus exec "$1" -- sudo dpkg --configure -a
incus exec "$1" -- sudo apt-get update
incus exec "$1" -- sudo apt-get install dos2unix curl -y
incus exec "$1" -- curl -L https://raw.githubusercontent.com/oneclickvirt/incus/main/ssh.sh -o ssh.sh
incus exec "$1" -- chmod 777 ssh.sh
incus exec "$1" -- dos2unix ssh.sh
incus exec "$1" -- sudo ./ssh.sh "$2"
echo "$2"
rm -rf "$0"
echo "$2"spiritlhlisyyds
