#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../scripts/image_lookup.sh
. "$ROOT_DIR/scripts/image_lookup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_normalized() {
    local input="$1"
    local expected_family="$2"
    local expected_version="$3"
    local expected_normalized="$4"
    normalize_image_system "$input" || fail "normalize_image_system rejected $input"
    [ "$a" = "$expected_family" ] || fail "$input family: got $a, want $expected_family"
    [ "$b" = "$expected_version" ] || fail "$input version: got $b, want $expected_version"
    [ "$normalized_system" = "$expected_normalized" ] || fail "$input normalized: got $normalized_system, want $expected_normalized"
}

assert_normalized "debian11" "debian" "11" "debian11"
assert_normalized "debian/11" "debian" "11" "debian11"
assert_normalized "images:ubuntu/20.04" "ubuntu" "20.04" "ubuntu20.04"
assert_normalized "centos-7" "centos" "7" "centos7"
assert_normalized "rocky8" "rockylinux" "8" "rockylinux8"

normalize_image_system "debian11"
match="$(
    printf '%s\n' \
        "gentoo_current_current_x86_64_cloud.zip" \
        "debian_11_bullseye_x86_64_cloud.zip" |
        find_matching_image_from_stream
)"
[ "$match" = "debian_11_bullseye_x86_64_cloud.zip" ] || fail "did not match debian11 in newline-separated custom image list"

normalize_image_system "ubuntu20"
image_name_matches_system "ubuntu_20.04_focal_x86_64_cloud.zip" || fail "ubuntu20 should match ubuntu_20.04 custom image"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/incus" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"type":"container","architecture":"x86_64","aliases":[]},
  {"type":"container","architecture":"x86_64","aliases":[{"name":"debian/11/cloud"}]},
  {"type":"container","architecture":"arm64","aliases":[{"name":"debian/11/arm64"}]},
  {"type":"virtual-machine","architecture":"x86_64","aliases":[{"name":"debian/11/vm"}]}
]
JSON
STUB
chmod +x "$tmpdir/incus"
PATH="$tmpdir:$PATH"

sys_bit="x86_64"
normalize_image_system "debian/11"
alias_name="$(find_remote_image_alias images container)"
[ "$alias_name" = "debian/11/cloud" ] || fail "container alias: got $alias_name"

alias_name="$(find_remote_image_alias images virtual-machine)"
[ "$alias_name" = "debian/11/vm" ] || fail "VM alias: got $alias_name"

echo "image lookup tests passed"
