#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

definition=$(awk '$0 == "remove_incus_ipv6_cron() {" { active=1 } active { print } active && /^}$/ { exit }' \
    "$repo_root/scripts/uninstall_incus.sh")
[ -n "$definition" ] || { echo 'missing remove_incus_ipv6_cron' >&2; exit 1; }
eval "$definition"
_yellow() { :; }
incus_other_runtime_uses_ipv6_cron() { return 1; }
if ! command -v flock >/dev/null 2>&1; then
    flock() { return 0; }
fi
stat_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

expected="*/1 * * * * root curl --noproxy '*' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb && curl --noproxy '*' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb"
export OCV_IPV6_CRON_FILE="$test_dir/cron.d/oneclickvirt-ipv6"
export OCV_IPV6_CRON_LOCK="$test_dir/lock/oneclickvirt-ipv6.lock"
mkdir -p "${OCV_IPV6_CRON_FILE%/*}"

printf '%s\n' "$expected" >"$OCV_IPV6_CRON_FILE"
remove_incus_ipv6_cron
[ ! -e "$OCV_IPV6_CRON_FILE" ] || { echo 'owned-only cron survived' >&2; exit 1; }

printf '%s\n' '# administrator entry' "$expected" '5 * * * * root /usr/local/sbin/custom-job' >"$OCV_IPV6_CRON_FILE"
chmod 0640 "$OCV_IPV6_CRON_FILE"
remove_incus_ipv6_cron
grep -Fxq '# administrator entry' "$OCV_IPV6_CRON_FILE"
grep -Fxq '5 * * * * root /usr/local/sbin/custom-job' "$OCV_IPV6_CRON_FILE"
! grep -Fxq "$expected" "$OCV_IPV6_CRON_FILE"
[ "$(stat_mode "$OCV_IPV6_CRON_FILE")" = 640 ]

cp "$OCV_IPV6_CRON_FILE" "$test_dir/expected"
remove_incus_ipv6_cron
cmp "$test_dir/expected" "$OCV_IPV6_CRON_FILE"

mv "$OCV_IPV6_CRON_FILE" "$test_dir/real-cron"
ln -s "$test_dir/real-cron" "$OCV_IPV6_CRON_FILE"
remove_incus_ipv6_cron
[ -L "$OCV_IPV6_CRON_FILE" ]

rm -f "$OCV_IPV6_CRON_FILE"
printf '%s\n' "$expected" >"$OCV_IPV6_CRON_FILE"
incus_other_runtime_uses_ipv6_cron() { return 0; }
remove_incus_ipv6_cron
grep -Fxq "$expected" "$OCV_IPV6_CRON_FILE"

incus_other_runtime_uses_ipv6_cron() { return 1; }
rm -f "$OCV_IPV6_CRON_LOCK"
ln -s "$test_dir/real-cron" "$OCV_IPV6_CRON_LOCK"
if remove_incus_ipv6_cron; then
    echo 'symlink lock was accepted' >&2
    exit 1
fi
grep -Fxq "$expected" "$OCV_IPV6_CRON_FILE"

printf 'PASS: Incus uninstall removes only its unshared exact IPv6 cron entry\n'
