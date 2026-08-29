#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/incus-build-flow-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_create_failure_test() {
    local kind="$1"
    local script="$repo_root/scripts/build${kind}.sh"
    local workdir="$tmpdir/${kind}-create"
    mkdir -p "$workdir"

    (
        cd "$workdir"
        export ONECLICKVIRT_TESTING=1
        # shellcheck disable=SC1090
        source "$script"

        local incus_log="$workdir/incus.log"
        local continued="$workdir/continued"
        incus() {
            printf '%s\n' "$*" >>"$incus_log"
            case "${1:-}" in
            init | info)
                return 1
                ;;
            *)
                return 0
                ;;
            esac
        }
        ensure_incus_ready() { :; }
        check_vm_support() { :; }
        check_china() { :; }
        check_cdn_file() { :; }
        detect_arch() { :; }
        detect_os() { :; }
        install_dependencies() { :; }
        normalize_image_system() {
            normalized_system="$1"
            return 0
        }
        handle_image() {
            image_download_url=""
            status_tuna=false
            fixed_system=false
        }
        mark_continuation() {
            : >"$continued"
        }
        configure_storage() { mark_continuation; }
        configure_limits() { mark_continuation; }
        apply_template() { mark_continuation; }
        setup_container() { mark_continuation; }
        setup_vm() { mark_continuation; }
        cleanup_and_finish() { mark_continuation; }

        if main create-case 1 256 2 20001 0 0 100 100 N debian12 >output 2>&1; then
            fail "build${kind}: main succeeded after incus init failed"
        fi
        [ ! -e "$continued" ] || fail "build${kind}: configuration continued after incus init failed"
        [ ! -e create-case ] || fail "build${kind}: wrote a success record after incus init failed"
        grep -Eq '^init ' "$incus_log" || fail "build${kind}: incus init was not attempted"
        if grep -Fq 'completed successfully' output; then
            fail "build${kind}: printed a success message after incus init failed"
        fi
    )
}

run_rollback_cleanup_test() {
    local kind="$1"
    local script="$repo_root/scripts/build${kind}.sh"
    local workdir="$tmpdir/${kind}-rollback"
    mkdir -p "$workdir"

    (
        cd "$workdir"
        export ONECLICKVIRT_TESTING=1
        # shellcheck disable=SC1090
        source "$script"

        local incus_log="$workdir/incus.log"
        incus() {
            printf '%s\n' "$*" >>"$incus_log"
            return 0
        }
        name="rollback-${kind}"
        created_instance=true
        build_succeeded=false
        trap cleanup_failed_instance EXIT
        exit 1
    ) && fail "build${kind}: failed invocation returned success"

    grep -Fxq "delete --force rollback-${kind}" "$workdir/incus.log" ||
        fail "build${kind}: failed invocation did not remove its new instance"

    (
        cd "$workdir"
        export ONECLICKVIRT_TESTING=1
        # shellcheck disable=SC1090
        source "$script"

        local incus_log="$workdir/preexisting.log"
        incus() {
            printf '%s\n' "$*" >>"$incus_log"
            return 0
        }
        name="preexisting-${kind}"
        created_instance=false
        build_succeeded=false
        trap cleanup_failed_instance EXIT
        exit 1
    ) && fail "build${kind}: pre-existing instance path returned success"

    [ ! -e "$workdir/preexisting.log" ] ||
        fail "build${kind}: cleanup touched a pre-existing instance"
}

run_init_status_tracking_test() {
    local kind="$1"
    local script="$repo_root/scripts/build${kind}.sh"
    local workdir="$tmpdir/${kind}-init-status"
    mkdir -p "$workdir"

    (
        cd "$workdir"
        export ONECLICKVIRT_TESTING=1
        # shellcheck disable=SC1090
        source "$script"

        local incus_log="$workdir/incus.log"
        name="late-${kind}"
        created_instance=false
        build_succeeded=false
        incus() {
            printf '%s\n' "$*" >>"$incus_log"
            case "${1:-}" in
            init) return 42 ;;
            info) return 0 ;;
            delete) return 0 ;;
            esac
            return 0
        }

        local init_status=0
        if create_instance_with_tracking incus init image "$name"; then
            fail "build${kind}: late init failure was reported as success"
        else
            init_status=$?
        fi
        [ "$init_status" -eq 42 ] || fail "build${kind}: init status changed from 42 to ${init_status}"
        [ "$created_instance" = true ] || fail "build${kind}: late-created instance was not tracked"
        cleanup_failed_instance || true
        grep -Fxq "delete --force $name" "$incus_log" ||
            fail "build${kind}: late-created instance was not removed"
    )
}

run_configuration_failure_cleanup_test() {
    local kind="$1"
    local script="$repo_root/scripts/build${kind}.sh"
    local workdir="$tmpdir/${kind}-configure"
    mkdir -p "$workdir"

    (
        cd "$workdir"
        export ONECLICKVIRT_TESTING=1
        # shellcheck disable=SC1090
        source "$script"

        local incus_log="$workdir/incus.log"
        local exists=false
        incus() {
            printf '%s\n' "$*" >>"$incus_log"
            case "${1:-}" in
            init)
                exists=true
                return 0
                ;;
            info)
                if [ "$exists" = true ]; then
                    return 0
                fi
                return 1
                ;;
            delete)
                exists=false
                return 0
                ;;
            esac
            return 0
        }
        ensure_incus_ready() { :; }
        check_vm_support() { KVM_AVAILABLE=true; }
        check_china() { :; }
        check_cdn_file() { :; }
        detect_arch() { :; }
        detect_os() { :; }
        install_dependencies() { :; }
        normalize_image_system() { normalized_system="$1"; }
        handle_image() {
            image_download_url=""
            status_tuna=false
            fixed_system=false
        }
        configure_limits() { return 37; }
        configure_storage() { :; }
        apply_template() { :; }
        trap cleanup_failed_instance EXIT
        if main configure-case 1 256 2 20001 0 0 100 100 N debian12 >output 2>&1; then
            fail "build${kind}: configuration failure was reported as success"
        fi
        exit 37
    ) && fail "build${kind}: configuration failure returned success"

    grep -Fxq 'delete --force configure-case' "$workdir/incus.log" ||
        fail "build${kind}: configuration failure did not roll back the instance"
    [ ! -e "$workdir/configure-case" ] ||
        fail "build${kind}: configuration failure wrote a success record"
}

run_mirror_package_failure_test() {
    local kind="$1"
    local script="$repo_root/scripts/build${kind}.sh"
    local workdir="$tmpdir/${kind}-mirror-package"
    mkdir -p "$workdir"

    (
        cd "$workdir"
        export ONECLICKVIRT_TESTING=1
        # shellcheck disable=SC1090
        source "$script"

        name="mirror-${kind}"
        CN=true
        system=debian12
        incus() {
            if [[ "$*" == *'yum install -y curl'* ]]; then
                return 88
            fi
            return 0
        }
        if setup_mirror_and_packages; then
            fail "build${kind}: mirror package installation failure was ignored"
        fi
    )
}

run_create_failure_test ct
run_create_failure_test vm
run_rollback_cleanup_test ct
run_rollback_cleanup_test vm
run_init_status_tracking_test ct
run_init_status_tracking_test vm
run_configuration_failure_cleanup_test ct
run_configuration_failure_cleanup_test vm
run_mirror_package_failure_test ct
run_mirror_package_failure_test vm

printf 'Incus build failure control-flow tests passed\n'
