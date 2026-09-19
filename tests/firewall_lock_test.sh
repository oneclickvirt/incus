#!/usr/bin/env bash
# Real process serialization of installer/uninstaller firewall transactions.
set -euo pipefail
if ! command -v flock >/dev/null 2>&1; then
    printf 'SKIP: firewall lock test requires util-linux flock (Linux host prerequisite)\n' >&2
    exit 75
fi
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [ -f "$repo_root/scripts/incus_install.sh" ]; then
    entries=(incus_install.sh uninstall_incus.sh)
else
    entries=(lxdinstall.sh lxduninstall.sh)
fi
load_lock() {
    local entry="$1" name definition
    for name in ocv_lock_firewall ocv_with_firewall_lock; do
        definition=$(awk -v name="$name" '$0==name "() {" { active=1 } active {print} active && /^}$/ {exit}' "$repo_root/scripts/$entry")
        [ -n "$definition" ] || fail "missing $name"
        eval "${definition//\/run\/oneclickvirt-firewall-locks/$test_dir/lock}"
    done
}
record_operation() {
    printf '%s start\n' "$1" >>"$test_dir/events"
    sleep 0.2
    printf '%s end\n' "$1" >>"$test_dir/events"
}
( load_lock "${entries[0]}"; ocv_with_firewall_lock record_operation install ) &
first=$!
( load_lock "${entries[1]}"; ocv_with_firewall_lock record_operation uninstall ) &
second=$!
wait "$first"
wait "$second"
awk 'NR==1 {owner=$1} NR==2 {if($1!=owner || $2!="end") exit 1} NR==3 {if($1==owner || $2!="start") exit 1; owner=$1} NR==4 {if($1!=owner || $2!="end") exit 1} END {if(NR!=4) exit 1}' "$test_dir/events" || fail 'firewall operations interleaved'
load_lock "${entries[0]}"
inode=$(stat -c %i "$test_dir/lock/firewall.lock")
if ocv_with_firewall_lock false; then fail 'wrapped failure was hidden'; fi
ocv_with_firewall_lock true
[ "$(stat -c %i "$test_dir/lock/firewall.lock")" = "$inode" ] || fail 'lock inode replaced'
mv "$test_dir/lock" "$test_dir/original-lock"
ln -s "$test_dir/original-lock" "$test_dir/lock"
if ocv_with_firewall_lock true; then fail 'symlink lock directory accepted'; fi
printf 'PASS: real installer/uninstaller mutual exclusion, failure release and lock identity\n'
