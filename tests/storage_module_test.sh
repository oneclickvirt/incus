#!/usr/bin/env bash
# Execute real installer functions with isolated paths and mocked package/kernel
# commands. This is fault injection, not clean-OS or runtime acceptance.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -f "$repo_root/scripts/incus_install.sh" ]]; then runtime=incus; else runtime=lxd; fi
case "$runtime" in
    incus) installer="$repo_root/scripts/incus_install.sh" ;;
    lxd) installer="$repo_root/scripts/lxdinstall.sh" ;;
    *) printf 'Unknown repository\n' >&2; exit 1 ;;
esac
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer" |
        sed "s#/usr/local/bin/${runtime}_#$test_dir/#g")
}
load_function ensure_storage_kernel_support
load_function init_storage_backend
# Driver-cache refresh has its own regression suite. This suite retains the
# original package/kernel/fallback cases without mocking those new assertions.
ensure_storage_driver_ready() { return 0; }
_green() { :; }
_yellow() { :; }
_red() { :; }
count=0
for backend in btrfs lvm zfs; do
    for scenario in fresh ready builtin unavailable package_failed init_failed; do
        (
            calls="$test_dir/$backend-$scenario"
            mkdir "$calls"
            disk_nums=12 storage_path=""
            PACKAGETYPE_INSTALL=install_package
            mock_installed=false
            [[ "$scenario" != ready && "$scenario" != builtin ]] || mock_installed=true
            active_storage_pool() { return 1; }
            is_storage_tried() { return 1; }
            is_storage_installed() { "$mock_installed"; }
            record_installed_storage() { mock_installed=true; }
            record_tried_storage() { printf '%s\n' "$1" >"$calls/tried"; }
            record_storage_pool() { printf '%s\n' "$1" >"$calls/pool"; }
            storage_pool_exists() { test -f "$calls/init"; }
            command() {
                if [[ "$1" == -v && "$2" == "$backend" ]]; then "$mock_installed"; else builtin command "$@"; fi
            }
            install_package() {
                printf '%s\n' "$1" >>"$calls/packages"
                [[ "$scenario" != package_failed ]]
            }
            grep() {
                case "${*: -1}" in
                    /proc/filesystems|/proc/modules|/proc/devices) [[ "$scenario" == builtin ]] ;;
                    *) builtin command grep "$@" ;;
                esac
            }
            modprobe() {
                printf '%s\n' "$1" >>"$calls/modules"
                [[ "$scenario" != unavailable && "$scenario" != builtin ]]
            }
            execute_storage_init() {
                printf '%s\n' "$backend" >"$calls/init"
                [[ "$scenario" != init_failed ]]
            }
            incus() { execute_storage_init "$backend"; }
            rm -f -- "$test_dir/reboot" "$test_dir/storage_type"
            status=0
            init_storage_backend "$backend" >"$calls/output" 2>&1 || status=$?
            case "$scenario" in
                fresh|ready|builtin)
                    [[ "$status" == 0 && -f "$calls/init" ]] || fail "$runtime/$backend/$scenario skipped a usable backend"
                    [[ ! -e "$test_dir/reboot" ]] || fail 'usable backend must not request reboot'
                    [[ "$(cat "$test_dir/storage_type")" == "$backend" ]] || fail 'wrong backend recorded'
                    ;;
                unavailable)
                    [[ "$status" != 0 && ! -e "$calls/init" ]] || fail 'unavailable module must allow fallback before init'
                    [[ "$(cat "$test_dir/reboot")" == "$backend" ]] || fail 'unavailable module lost recovery marker'
                    ;;
                package_failed)
                    [[ "$status" != 0 && ! -e "$calls/init" && ! -e "$calls/modules" ]] || fail 'package failure was ignored'
                    ;;
                init_failed)
                    [[ "$status" != 0 && -e "$calls/init" && ! -e "$test_dir/storage_type" ]] || fail 'runtime init failure was ignored'
                    ;;
            esac
            case "$scenario" in
                ready|builtin) [[ ! -e "$calls/packages" ]] || fail 'existing userspace tools reinstalled' ;;
                *) [[ -s "$calls/packages" ]] || fail 'missing userspace package not installed' ;;
            esac
            if [[ "$scenario" == builtin ]]; then
                [[ ! -e "$calls/modules" ]] || fail 'already available kernel support must not need modprobe'
            fi
        )
        count=$((count + 1))
    done
done
printf 'PASS: %s storage module initialization (%s scenarios, no skipped tests)\n' "$runtime" "$count"
