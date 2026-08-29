#!/usr/bin/env bash
# shellcheck disable=SC1090
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/scripts/incus_install.sh"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/incus-storage-preservation-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_absent() {
    local pattern="$1"
    if grep -Fq -- "$pattern" "$installer"; then
        fail "installer still contains destructive operation: $pattern"
    fi
}

assert_absent 'storage delete default'
assert_absent 'storage volume delete default'
assert_absent 'profile device remove default root'
grep -Fq 'MANAGED_STORAGE_POOL="oneclickvirt"' "$installer" || fail 'missing managed custom pool'

for script in "$repo_root/scripts/buildct.sh" "$repo_root/scripts/buildvm.sh"; do
    grep -Fq 'incus_storage_pool()' "$script" || fail "missing storage pool selector in $script"
    grep -Fq -- '-s "${storage_pool:-default}"' "$script" || fail "build script does not select recorded pool: $script"
done

(
    # Load only function definitions. The real installer normally changes to
    # /root, which is intentionally skipped for this isolated unit test.
    ONECLICKVIRT_TESTING=1 source <(sed 's|^cd /root.*|:|' "$installer")
    TRIED_STORAGE_FILE="$tmpdir/tried"
    INSTALLED_STORAGE_FILE="$tmpdir/installed"
    STORAGE_POOL_FILE="$tmpdir/pool"
    storage_path="$tmpdir/custom"
    storage_pool_exists() { [ "${1:-default}" = "default" ]; }
    record_storage_pool() { printf '%s\n' "$1" >"$STORAGE_POOL_FILE"; }
    init_storage_backend() { : >"$tmpdir/backend-called"; return 1; }

    setup_storage
    [ "$(cat "$STORAGE_POOL_FILE")" = "default" ] || fail 'existing default pool was not recorded'
    [ ! -e "$tmpdir/backend-called" ] || fail 'existing default pool triggered backend initialization'
)

(
    ONECLICKVIRT_TESTING=1 source <(sed 's|^cd /root.*|:|' "$installer")
    TRIED_STORAGE_FILE="$tmpdir/custom-tried"
    INSTALLED_STORAGE_FILE="$tmpdir/custom-installed"
    STORAGE_POOL_FILE="$tmpdir/custom-pool"
    storage_path="$tmpdir/custom-storage"
    disk_nums=1
    call_log="$tmpdir/custom-calls"
    pool_created=false
    incus() {
        printf '%s\n' "$*" >>"$call_log"
        case "$*" in
            'storage show oneclickvirt')
                [ "$pool_created" = true ]
                ;;
            'admin init --auto')
                return 0
                ;;
            'storage create oneclickvirt dir source='*)
                pool_created=true
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    }

    initialize_custom_storage_pool dir
    [ "$(cat "$STORAGE_POOL_FILE")" = "oneclickvirt" ] || fail 'custom pool was not recorded'
    grep -Fxq 'admin init --auto' "$call_log" || fail 'fresh custom storage did not initialize Incus first'
    grep -Fq 'storage create oneclickvirt dir source=' "$call_log" || fail 'fresh custom storage did not create the managed pool'
)

printf 'Incus storage-pool preservation tests passed\n'
