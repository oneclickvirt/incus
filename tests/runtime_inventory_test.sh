#!/usr/bin/env bash
# CLI contract regression: the mock rejects unsupported LTS column options.
# No packages, daemons, host paths or live network state are modified.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [[ -f "$repo_root/scripts/incus_install.sh" ]]; then
    entries=(scripts/incus_install.sh panel_scripts/panel_init.sh)
else
    entries=(scripts/lxdinstall.sh panel_scripts/panel_init.sh scripts/lxduninstall.sh)
fi
mock_runtime() {
    printf '%s\n' "$*" >>"$test_dir/calls"
    case "$*" in
        'storage list --format json'|'--force-local --project default storage list --format json') ;;
        *) printf 'unsupported CLI arguments: %s\n' "$*" >&2; return 88 ;;
    esac
    printf '%s' "$payload"
    return "$command_status"
}
lxc() { mock_runtime "$@"; }
incus() { mock_runtime "$@"; }
LXC_CMD=(mock_runtime --force-local --project default)
count=0
for entry in "${entries[@]}"; do
    source <(awk '$0 == "runtime_resource_names() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$repo_root/$entry")
    for scenario in normal empty query_failure malformed object missing_name null_name blank_name empty_stdout multiple_documents; do
        payload='[{"name":"local"},{"name":"other-pool"}]' command_status=0
        case "$scenario" in
            empty) payload='[]' ;;
            query_failure) command_status=42 ;;
            malformed) payload='[' ;;
            object) payload='{"name":"local"}' ;;
            missing_name) payload='[{}]' ;;
            null_name) payload='[{"name":null}]' ;;
            blank_name) payload='[{"name":""}]' ;;
            empty_stdout) payload='' ;;
            multiple_documents) payload='[] []' ;;
        esac
        : >"$test_dir/calls"
        status=0
        result=$(runtime_resource_names storage 2>"$test_dir/error") || status=$?
        [[ "$(wc -l <"$test_dir/calls" | tr -d ' ')" == 1 ]] || fail 'inventory must use one CLI request'
        case "$scenario" in
            normal) [[ "$status:$result" == $'0:local\nother-pool' ]] || fail "$entry valid inventory failed" ;;
            empty) [[ "$status:$result" == '0:' ]] || fail "$entry empty list rejected" ;;
            *) [[ "$status" != 0 ]] || fail "$entry hid $scenario" ;;
        esac
        count=$((count + 1))
    done
done
printf 'PASS: runtime JSON inventories (%s scenarios, no skipped tests)\n' "$count"

