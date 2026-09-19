#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031
set -euo pipefail
if ! command -v flock >/dev/null 2>&1 || [ ! -d /proc/self/fd ]; then
    printf 'SKIP: script lock test requires util-linux flock and /proc/self/fd (Linux host prerequisite)\n' >&2
    exit 75
fi
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dir=$(mktemp -d)
holder="" competitor=""
cleanup() {
    [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
    [ -z "$competitor" ] || kill "$competitor" 2>/dev/null || true
    rm -rf -- "$task_dir"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export OCV_LOCK_TEST_HELPER="$repo_root/scripts/instance_ownership.sh"
export OCV_LOCK_TEST_DIR="$task_dir"
mkfifo "$task_dir/ready" "$task_dir/release" "$task_dir/competing"
(
    source "$OCV_LOCK_TEST_HELPER"
    OCV_SCRIPT_RUNTIME=fixture
    ocv_lock_scripts "$task_dir/locks"
    # A batch launches a child builder under the same lock without deadlock.
    timeout 5 bash -c 'source "$OCV_LOCK_TEST_HELPER"; OCV_SCRIPT_RUNTIME=fixture; ocv_lock_scripts "$OCV_LOCK_TEST_DIR/locks"'
    printf 'ready\n' >"$task_dir/ready"
    IFS= read -r _ <"$task_dir/release"
) &
holder=$!
IFS= read -r _ <"$task_dir/ready"
inode=$(stat -c %i "$task_dir/locks/scripts.lock")
(
    source "$OCV_LOCK_TEST_HELPER"
    OCV_SCRIPT_RUNTIME=other-runtime
    # A stale environment hint alone does not grant ownership.
    _OCV_SCRIPT_LOCK_FD=99 _OCV_SCRIPT_LOCK_SCOPE=shared-files-v1
    printf 'attempting\n' >"$task_dir/competing"
    ocv_lock_scripts "$task_dir/locks"
    : >"$task_dir/acquired"
) &
competitor=$!
IFS= read -r _ <"$task_dir/competing"
sleep 0.2
[ ! -e "$task_dir/acquired" ] || fail "overlapping callers acquired the shared lock"
printf 'release\n' >"$task_dir/release"
wait "$holder"
holder=""
wait "$competitor"
competitor=""
[ -e "$task_dir/acquired" ] || fail "waiting caller did not resume"
[ "$inode" = "$(stat -c %i "$task_dir/locks/scripts.lock")" ] || fail "lock inode was replaced"
(
    source "$OCV_LOCK_TEST_HELPER"
    OCV_SCRIPT_RUNTIME=fixture
    mkdir "$task_dir/unsafe"
    chmod 777 "$task_dir/unsafe"
    if ocv_lock_scripts "$task_dir/unsafe"; then fail "accepted writable lock directory"; fi
    ln -s "$task_dir/locks" "$task_dir/link"
    if ocv_lock_scripts "$task_dir/link"; then fail "accepted symlink lock directory"; fi
)
printf 'PASS: real process exclusion, child inheritance, stale hints and lock integrity\n'
