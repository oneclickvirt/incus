#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/incus-batch-transaction.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

write_fake_builder() {
    local destination="$1"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -u' \
        'name=$1' \
        'count=$(cat "$MOCK_COUNT_FILE" 2>/dev/null || printf 0)' \
        'count=$((count + 1))' \
        'printf "%s\n" "$count" >"$MOCK_COUNT_FILE"' \
        ': >"$MOCK_STATE_DIR/${name}.exists"' \
        'if [ "$count" -eq "${MOCK_FAIL_ON:-0}" ]; then exit 42; fi' \
        'printf "%s\n" "$name $5 test-password $6 $7" >"$name"' \
        >"$destination"
    chmod +x "$destination"
}

run_add_case() (
    local case_name="$1"
    local fail_on="$2"
    local preexisting="$3"
    local case_dir="$tmpdir/add-$case_name"
    mkdir -p "$case_dir/state"
    cd "$case_dir"
    write_fake_builder "$case_dir/buildct.sh"
    printf '0\n' >count
    printf '%s\n' 'legacy0 20000 old-password 30000 30024' >log
    if [ "$preexisting" = true ]; then
        : >state/ct1.exists
        printf '%s\n' 'ct1 20001 existing-password 30025 30049' >ct1
    fi

    export ONECLICKVIRT_TESTING=1
    export INCUS_NONINTERACTIVE=1
    export INCUS_ADD_NUMS=2
    export INCUS_ADD_CPU=1
    export INCUS_ADD_MEMORY=128
    export INCUS_ADD_DISK=1
    export INCUS_ADD_DOWNLOAD=100
    export INCUS_ADD_UPLOAD=100
    export INCUS_ADD_IPV6=N
    export INCUS_ADD_SYSTEM=debian12
    export MOCK_STATE_DIR="$case_dir/state"
    export MOCK_COUNT_FILE="$case_dir/count"
    export MOCK_FAIL_ON="$fail_on"
    # shellcheck source=/dev/null
    source "$repo_root/scripts/add_more.sh"

    normalize_image_system() { normalized_system="$1"; }
    cdn_success_url=""
    curl() { printf 'debian12\n'; }
    find_matching_image_from_stream() { cat >/dev/null; printf 'debian12\n'; }
    find_remote_image_alias() { printf 'debian12\n'; }
    incus() {
        case "${1:-}" in
        info) [ -e "$MOCK_STATE_DIR/${2}.exists" ] ;;
        delete) rm -f -- "$MOCK_STATE_DIR/${3}.exists" ;;
        *) return 0 ;;
        esac
    }
    container_prefix=ct
    container_num=0
    ssh_port=20000
    public_port_end=30000

    if [ "$case_name" = success ]; then
        build_new_containers >/dev/null
    elif build_new_containers >/dev/null 2>&1; then
        fail "$case_name add_more batch unexpectedly succeeded"
    else
        exit 42
    fi
)

if run_add_case second-failure 2 false; then
    fail 'failed add_more case returned success'
fi
add_failure_dir="$tmpdir/add-second-failure"
[ "$(cat "$add_failure_dir/log")" = 'legacy0 20000 old-password 30000 30024' ] || fail 'failed add_more batch changed the old log'
[ ! -e "$add_failure_dir/state/ct1.exists" ] || fail 'failed add_more batch left the first instance'
[ ! -e "$add_failure_dir/state/ct2.exists" ] || fail 'failed add_more batch left the partial instance'

run_add_case success 0 false
add_success_dir="$tmpdir/add-success"
[ "$(wc -l <"$add_success_dir/log" | tr -d ' ')" -eq 3 ] || fail 'successful add_more batch did not append both records'
[ -e "$add_success_dir/state/ct1.exists" ] && [ -e "$add_success_dir/state/ct2.exists" ] || fail 'successful add_more batch removed an instance'

if run_add_case preexisting 0 true; then
    fail 'pre-existing add_more case returned success'
fi
add_preexisting_dir="$tmpdir/add-preexisting"
[ "$(cat "$add_preexisting_dir/count")" -eq 0 ] || fail 'builder ran for a pre-existing instance'
[ -e "$add_preexisting_dir/state/ct1.exists" ] || fail 'pre-existing instance was deleted'
grep -Fxq 'ct1 20001 existing-password 30025 30049' "$add_preexisting_dir/ct1" || fail 'pre-existing record was changed'

run_transaction_failure() (
    local script_name="$1"
    local case_dir="$tmpdir/${script_name%.sh}-failure"
    mkdir -p "$case_dir/state"
    cd "$case_dir"
    printf '%s\n' 'old-log-entry' >log
    export ONECLICKVIRT_TESTING=1
    # shellcheck source=/dev/null
    source "$repo_root/scripts/$script_name"
    incus() {
        case "${1:-}" in
        delete) rm -f -- "$case_dir/state/${3}.exists" ;;
        info) [ -e "$case_dir/state/${2}.exists" ] ;;
        *) return 0 ;;
        esac
    }
    begin_batch
    : >"state/base.exists"
    : >"state/child.exists"
    track_batch_instance base
    track_batch_instance child
    printf '%s\n' 'new-log-entry' >"$batch_pending_log"
    exit 73
)

for script_name in init.sh least.sh; do
    if run_transaction_failure "$script_name"; then
        fail "$script_name failed transaction returned success"
    fi
    case_dir="$tmpdir/${script_name%.sh}-failure"
    [ "$(cat "$case_dir/log")" = 'old-log-entry' ] || fail "$script_name changed the old log on failure"
    [ ! -e "$case_dir/state/base.exists" ] || fail "$script_name did not roll back the base instance"
    [ ! -e "$case_dir/state/child.exists" ] || fail "$script_name did not roll back the child instance"
    if grep -Eq 'rm -r?f --? log|>>[[:space:]]*log' "$repo_root/scripts/$script_name"; then
        fail "$script_name still deletes or appends directly to the committed log"
    fi
    grep -Fq 'commit_batch_log' "$repo_root/scripts/$script_name" || fail "$script_name does not commit the staged log"
done

run_main_configuration_failure() (
    local script_name="$1"
    local case_dir="$tmpdir/${script_name%.sh}-main-failure"
    mkdir -p "$case_dir/state"
    cd "$case_dir"
    printf '%s\n' 'old-log-entry' >log
    export ONECLICKVIRT_TESTING=1
    # shellcheck source=/dev/null
    source "$repo_root/scripts/$script_name"
    incus() {
        case "${1:-}" in
        storage) return 0 ;;
        info) [ -e "$case_dir/state/${2}.exists" ] ;;
        delete) rm -f -- "$case_dir/state/${3}.exists" ;;
        *) return 0 ;;
        esac
    }
    setup_directories() { :; }
    check_china() { :; }
    check_cdn_file() { :; }
    detect_arch() { sys_bit=x86_64; }
    create_base_container() { : >"$case_dir/state/base.exists"; }
    configure_storage() { :; }
    setup_storage() { :; }
    configure_network() { return 66; }
    configure_resources() {
        if [ "$script_name" = least.sh ]; then
            return 66
        fi
        : >"$case_dir/configuration-continued"
    }
    block_ports() { :; }
    download_scripts() { :; }
    cleanup() { :; }

    set +e
    main base 1 >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$script_name ignored a required base configuration failure"
    exit "$status"
)

for script_name in init.sh least.sh; do
    if run_main_configuration_failure "$script_name"; then
        fail "$script_name main failure case returned success"
    fi
    case_dir="$tmpdir/${script_name%.sh}-main-failure"
    [ "$(cat "$case_dir/log")" = 'old-log-entry' ] || fail "$script_name main failure changed the old log"
    [ ! -e "$case_dir/state/base.exists" ] || fail "$script_name main failure did not remove its base instance"
    [ ! -e "$case_dir/configuration-continued" ] || fail "$script_name continued after a required configuration failure"
done

printf 'Incus batch transaction tests passed\n'
