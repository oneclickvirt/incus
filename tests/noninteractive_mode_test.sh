#!/usr/bin/env bash
# Exercise mode selection and child-process inheritance without running installers.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
count=0
load_function() {
    local source
    source=$(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$file")
    [ -z "$source" ] || eval "$source"
}
while IFS= read -r file; do
    grep -q '^is_noninteractive() {' "$file" || continue
    (
        unset -f is_noninteractive is_truthy is_true 2>/dev/null || true
        load_function is_truthy
        load_function is_true
        load_function is_noninteractive
        check_mode() {
            local expected="$1" canonical="$2" alias="$3" legacy="$4"
            unset noninteractive NONINTERACTIVE INCUS_NONINTERACTIVE INCUS_FORCE_UNINSTALL FORCE_UNINSTALL FORCE
            [ "$canonical" = unset ] || noninteractive="$canonical"
            [ "$alias" = unset ] || NONINTERACTIVE="$alias"
            [ "$legacy" = unset ] || INCUS_NONINTERACTIVE="$legacy"
            actual=false
            if is_noninteractive; then actual=true; fi
            if [ "$actual" != "$expected" ]; then
                printf 'FAIL %s: canonical=%s alias=%s legacy=%s -> %s (expected %s)\n' "$file" "$canonical" "$alias" "$legacy" "$actual" "$expected" >&2
                exit 1
            fi
            # Mode normalization must reach children even for shell-local flags.
            child=$(bash -c 'printf "%s" "${noninteractive:-}"')
            [ "$child" = "${noninteractive:-}" ] || exit 1
        }
        check_mode false unset unset unset
        for value in true TRUE True tRuE yes YES Yes y Y 1; do
            check_mode true "$value" unset unset
            check_mode true unset "$value" unset
        done
        for value in false FALSE no NO n N 0 invalid; do
            check_mode false "$value" true true
        done
        check_mode true true false false
        check_mode false unset false true
        if grep -q 'INCUS_NONINTERACTIVE' "$file"; then
            check_mode true unset unset true
        fi
    )
    count=$((count + 1))
done < <(find "$repo_root" -path '*/.git' -prune -o -path '*/tests' -prune -o -path '*/temp' -prune -o -type f -name '*.sh' -print)
[ "$count" -gt 0 ] || { echo 'No mode selectors tested' >&2; exit 1; }
printf 'PASS: unattended flag contract and child inheritance in %s script entry points\n' "$count"

