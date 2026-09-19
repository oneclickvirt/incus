#!/usr/bin/env bash
# Daemon capability caching is independent of installed userspace/kernel support.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/incus_install.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for name in api_metadata runtime_resource_names ensure_storage_driver_ready; do
    source <(awk -v name="$name" '$0 == name "() {" {active=1} active {print} active && /^}$/ {exit}' "$installer")
done
_red() { :; }
_yellow() { :; }
count=0
for shape in direct envelope; do
    for scenario in ready stale restart_failure wait_failure still_missing query_failure empty multiple invalid_drivers pool_query_failure existing_pool; do
        (
            set +o pipefail
            restarted=0 waited=0
            service_manager() {
                [[ "$*" == 'restart incus' ]] || fail 'unexpected service mutation'
                restarted=$((restarted + 1))
                [[ "$scenario" != restart_failure ]]
            }
            incus() {
                case "$*" in
                    'query /1.0')
                        payload='{"environment":{"storage_supported_drivers":[{"Name":"dir"}]}}'
                        if [[ "$scenario" == ready || ( "$restarted" == 1 && "$scenario" != still_missing ) ]]; then
                            payload='{"environment":{"storage_supported_drivers":[{"Name":"dir"},{"Name":"btrfs"}]}}'
                        fi
                        [[ "$shape" != envelope ]] || payload=$(jq -cn --argjson metadata "$payload" '{type:"sync",status_code:200,metadata:$metadata}')
                        case "$scenario" in
                            empty) payload='' ;;
                            multiple) payload="$payload $payload" ;;
                            invalid_drivers) payload='{"environment":{"storage_supported_drivers":{}}}' ;;
                        esac
                        printf '%s\n' "$payload"
                        [[ "$scenario" != query_failure ]] ;;
                    'storage list --format json')
                        if [[ "$scenario" == existing_pool ]]; then printf '[{"name":"local"}]\n'; else printf '[]\n'; fi
                        [[ "$scenario" != pool_query_failure ]] ;;
                    'admin waitready --timeout=120')
                        waited=$((waited + 1))
                        [[ "$scenario" != wait_failure ]] ;;
                    *) fail "unexpected command: $*" ;;
                esac
            }
            status=0
            ensure_storage_driver_ready btrfs >/dev/null 2>&1 || status=$?
            case "$scenario" in
                ready) [[ "$status:$restarted:$waited" == 0:0:0 ]] || fail 'ready driver was restarted' ;;
                stale) [[ "$status:$restarted:$waited" == 0:1:1 ]] || fail 'newly installed driver was not refreshed' ;;
                restart_failure) [[ "$status" != 0 && "$restarted:$waited" == 1:0 ]] || fail 'restart error ignored' ;;
                wait_failure|still_missing) [[ "$status" != 0 && "$restarted:$waited" == 1:1 ]] || fail 'failed refresh was retried or ignored' ;;
                *) [[ "$status" != 0 && "$restarted:$waited" == 0:0 ]] || fail "$scenario caused a restart or passed" ;;
            esac
        )
        count=$((count + 1))
    done
done
# Wire the checked refresh after kernel support and before init, not merely
# expose an unused helper that unit tests call directly.
body=$(awk '$0 == "init_storage_backend() {" {active=1} active {print} active && /^}$/ {exit}' "$installer")
kernel_line=$(grep -n 'ensure_storage_kernel_support "$backend" || return 1' <<<"$body" | cut -d: -f1)
refresh_line=$(grep -n 'ensure_storage_driver_ready "$backend" || return 1' <<<"$body" | cut -d: -f1)
init_line=$(grep -n 'temp=$(incus admin init --storage-backend' <<<"$body" | head -1 | cut -d: -f1)
[[ "$kernel_line" -lt "$refresh_line" && "$refresh_line" -lt "$init_line" ]] || fail 'driver refresh is not on the creation path'
printf 'PASS: Incus storage driver refresh (%s scenarios, no skipped tests)\n' "$count"
