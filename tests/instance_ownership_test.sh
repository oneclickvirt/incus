#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2329
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Run actual caller cleanup functions, with only daemon I/O replaced.
for entry in buildct buildvm init least add_more; do
    for scenario in partial collision replaced query-failure cleanup-query-failure delete-failure; do
        (
            export ONECLICKVIRT_TESTING=1
            source "$repo_root/scripts/$entry.sh"
            state_token="" state_uuid=original deleted=false mock_return_code=42 cleanup_started=false
            mock_cli() {
                case "$1" in
                    init|copy)
                        state_token="${!#}"; state_token="${state_token#*=}"
                        [[ "$state_token" =~ ^[a-f0-9]{32}$ ]] || fail "missing atomic creation marker"
                        if [ "$scenario" = collision ]; then state_token=someone-else; fi
                        return "$mock_return_code"
                        ;;
                    query)
                        [ "$scenario" != query-failure ] || return 1
                        if [ "$scenario" = cleanup-query-failure ] && [ "$cleanup_started" = true ]; then return 1; fi
                        jq -n --arg owner "$state_token" --arg uuid "$state_uuid" \
                            '{metadata:{config:{"user.oneclickvirt.creation-token":$owner,"volatile.uuid":$uuid}}}'
                        ;;
                    delete)
                        [ "$scenario" != delete-failure ] || return 1
                        deleted=true
                        ;;
                    *) fail "unexpected daemon call: $*" ;;
                esac
            }
            incus() { mock_cli "$@"; }
            lxc() { mock_cli "$@"; }
            name=owned-test
            if [[ "$entry" == build* ]]; then
                status=0
                create_instance_with_tracking "$OCV_INSTANCE_CLI" init image "$name" || status=$?
                [ "$status" -eq 42 ] || fail "$entry: failed init exit code changed"
                [ "$scenario" != replaced ] || state_uuid=replacement
                # Single-build cleanup captures daemon output in a subshell.
                # Record delete attempts independently of shell-local state.
                marker=$(mktemp)
                rm -f -- "$marker"
                original_cli=$OCV_INSTANCE_CLI
                OCV_INSTANCE_CLI=record_cli
                record_cli() {
                    if [ "$1" = delete ] && [ "$scenario" != delete-failure ]; then : >"$marker"; fi
                    "$original_cli" "$@"
                }
                cleanup_started=true
                cleanup_failed_instance || true
                if [ -f "$marker" ]; then deleted=true; rm -f -- "$marker"; fi
            else
                status=0
                ocv_create_owned "$name" "$OCV_INSTANCE_CLI" copy base "$name" || status=$?
                [ "$status" -eq 42 ] || fail "$entry: failed copy exit code changed"
                if [ "$entry" = add_more ]; then
                    add_creation_token="$state_token"
                    # A conflicting owner's token is not known to the caller.
                    [ "$scenario" != collision ] || add_creation_token=expected-token
                    track_add_batch_instance "$name" || true
                    [ "$scenario" != replaced ] || state_uuid=replacement
                    cleanup_started=true
                    rollback_add_batch
                else
                    track_batch_instance "$name" || true
                    [ "$scenario" != replaced ] || state_uuid=replacement
                    cleanup_started=true
                    rollback_batch
                fi
            fi
            if [ "$scenario" = partial ]; then
                [ "$deleted" = true ] || fail "$entry: partial owned instance was retained"
            else
                [ "$deleted" = false ] || fail "$entry: unsafe delete in $scenario"
            fi
        )
    done
done

(
    source "$repo_root/scripts/instance_ownership.sh"
    OCV_INSTANCE_CLI=mock_cli
    mock_cli() {
        case "$1" in
            init) return 0 ;;
            query) printf '%s\n' '{"config":{"user.oneclickvirt.creation-token":"other","volatile.uuid":"other"}}' ;;
            *) fail "unexpected command" ;;
        esac
    }
    if ocv_create_owned guest mock_cli init image guest; then
        fail "reported success without matching creation ownership"
    fi
    for invalid in '../guest' 'remote:guest' '-guest' 'guest?project=other' ''; do
        if ocv_instance_identity "$invalid"; then fail "accepted unsafe name"; fi
    done
)
printf 'PASS: 30 caller rollback cases, unverified success and unsafe names\n'
