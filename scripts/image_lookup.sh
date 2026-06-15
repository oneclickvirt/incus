#!/usr/bin/env bash
# Shared image name parsing and lookup helpers for Incus creation scripts.

strip_image_separators() {
    local value="$1"
    while [[ "$value" == [/:_.-]* ]]; do
        value="${value#?}"
    done
    while [[ "$value" == *[/:_.-] ]]; do
        value="${value%?}"
    done
    printf '%s\n' "$value"
}

canonical_image_family() {
    local family="$1"
    case "$family" in
    alma)
        family="almalinux"
        ;;
    rocky)
        family="rockylinux"
        ;;
    oraclelinux | oracle-linux | oracle_linux)
        family="oracle"
        ;;
    arch)
        family="archlinux"
        ;;
    esac
    printf '%s\n' "$family"
}

normalize_image_system() {
    local raw="${1:-}"
    local input prefix
    input="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    input="${input#images:}"
    input="${input#opsmaru:}"
    input="$(strip_image_separators "$input")"

    if [ -z "$input" ]; then
        return 1
    fi

    if [[ "$input" == */* ]]; then
        a="${input%%/*}"
        b="${input#*/}"
        b="${b%%/*}"
    else
        prefix="${input%%[0-9]*}"
        if [ "$prefix" != "$input" ]; then
            a="$prefix"
            b="${input#"$prefix"}"
        else
            a="$input"
            b=""
        fi
    fi

    a="$(strip_image_separators "$a")"
    b="$(strip_image_separators "$b")"
    a="$(canonical_image_family "$a")"
    normalized_system="${a}${b}"

    [ -n "$a" ]
}

image_name_matches_system() {
    local image_name="$1"
    [ -n "${a:-}" ] || return 1
    if [ -z "${b:-}" ]; then
        [[ "$image_name" == "${a}_"* ]]
        return
    fi
    [[ "$image_name" == "${a}_${b}"* ]]
}

find_matching_image_from_stream() {
    local image_name
    while IFS= read -r image_name; do
        [ -n "$image_name" ] || continue
        if image_name_matches_system "$image_name"; then
            printf '%s\n' "$image_name"
            return 0
        fi
    done
    return 1
}

remote_image_query() {
    if [ -n "${b:-}" ]; then
        printf '%s/%s\n' "$a" "$b"
    else
        printf '%s\n' "$a"
    fi
}

find_remote_image_alias() {
    local remote="$1"
    local image_type="$2"
    local query
    command -v incus >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    query="$(remote_image_query)"
    incus image list "${remote}:${query}" --format=json 2>/dev/null |
        jq -r --arg ARCHITECTURE "${sys_bit:-}" --arg IMAGE_TYPE "$image_type" '
            .[]?
            | select((.type // "") == $IMAGE_TYPE and (.architecture // "") == $ARCHITECTURE)
            | .aliases[]?
            | .name // empty
            | select(length > 0)
        ' |
        head -n 1
}
