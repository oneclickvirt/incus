#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Extract only the retry helper; the production entrypoint is intentionally
# not executed.  A transient curl failure must be handled inside the helper,
# even when callers enable `set -e`.
source <(sed -n '/^retry_curl() {/,/^}/p' "$ROOT_DIR/scripts/buildct.sh")

state_file=$(mktemp)
trap 'rm -f -- "$state_file"' EXIT
printf '0\n' >"$state_file"
curl() {
    curl_calls=$(($(<"$state_file") + 1))
    printf '%s\n' "$curl_calls" >"$state_file"
    if [[ "$curl_calls" -eq 1 ]]; then
        return 7
    fi
    printf '%s\n' 'payload'
}

retry_curl 'https://example.invalid'
[[ "$(<"$state_file")" -eq 2 ]]
[[ "$_retry_result" == payload ]]
printf '%s\n' 'Incus retry_curl set -e regression passed'
