#!/usr/bin/env bash
# Run platform branches with mocked executable availability and sysctl calls.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
_red() { :; }
_yellow() { :; }
load_function() {
    source <(awk -v name="$2" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$1")
}
for installer in "$repo_root/scripts/incus_install.sh" "$repo_root/panel_scripts/panel_init.sh"; do
    load_function "$installer" install_uidmap
    for pm in apt-get dnf yum apk pacman; do
        for mode in fresh partial ready install_failed helper_missing alpine_fallback; do
            (
                mock_uid=false mock_gid=false mock_installs=()
                [[ "$mode" != partial && "$mode" != ready ]] || mock_uid=true
                [[ "$mode" != ready ]] || mock_gid=true
                command() {
                    if [[ "$1" == -v ]]; then
                        case "$2" in
                            newuidmap) $mock_uid; return ;;
                            newgidmap) $mock_gid; return ;;
                            apt-get|dnf|yum|apk|pacman) [[ "$2" == "$pm" ]]; return ;;
                        esac
                    fi
                    builtin command "$@"
                }
                install_package() {
                    mock_installs+=("$1")
                    [[ "$mode" != install_failed ]] || return 1
                    if [[ "$mode" == alpine_fallback && "$1" == shadow-uidmap ]]; then return 1; fi
                    if [[ "$mode" != helper_missing ]]; then mock_uid=true mock_gid=true; fi
                }
                rc=0
                install_uidmap || rc=$?
                case "$mode" in
                    ready) [[ "$rc:${#mock_installs[@]}" == 0:0 ]] || fail 'existing helpers must avoid package changes'; exit 0 ;;
                    install_failed|helper_missing) [[ "$rc" != 0 ]] || fail "$pm/$mode must not pass"; exit 0 ;;
                esac
                [[ "$rc" == 0 ]] || fail "$pm/$mode should install both mapping helpers"
                case "$pm" in
                    apt-get) expected=uidmap ;;
                    dnf|yum) expected=shadow-utils ;;
                    apk)
                        expected=shadow-uidmap
                        [[ "$mode" != alpine_fallback ]] || expected='shadow-uidmap shadow' ;;
                    pacman) expected=shadow ;;
                esac
                [[ "${mock_installs[*]}" == "$expected" ]] || fail "$pm/$mode installed wrong packages: ${mock_installs[*]}"
            )
        done
    done
    load_function "$installer" apply_forwarding_config
    for scenario in success vendor_failure busybox own_file_failure forwarding_disabled; do
        (
            system_calls=0 file_calls=0
            sysctl() {
                case "$*" in
                    --help) [[ "$scenario" == busybox ]] || printf '%s\n' --system ;;
                    --system)
                        system_calls=$((system_calls + 1))
                        [[ "$scenario" != vendor_failure && "$scenario" != own_file_failure ]] ;;
                    '-p /test/forwarding.conf')
                        file_calls=$((file_calls + 1))
                        [[ "$scenario" != own_file_failure ]] ;;
                    '-n net.ipv4.ip_forward')
                        if [[ "$scenario" == forwarding_disabled ]]; then printf '0\n'; else printf '1\n'; fi ;;
                    *) fail "unexpected sysctl: $*" ;;
                esac
            }
            rc=0
            apply_forwarding_config /test/forwarding.conf || rc=$?
            case "$scenario" in
                success) [[ "$rc:$system_calls:$file_calls" == 0:1:0 ]] ;;
                vendor_failure) [[ "$rc:$system_calls:$file_calls" == 0:1:1 ]] ;;
                busybox) [[ "$rc:$system_calls:$file_calls" == 0:0:1 ]] ;;
                own_file_failure) [[ "$rc:$system_calls:$file_calls" == 1:1:1 ]] ;;
                forwarding_disabled) [[ "$rc:$system_calls:$file_calls" == 1:1:0 ]] ;;
            esac || fail "$scenario returned $rc, system=$system_calls own-file=$file_calls"
        )
    done
done
(
    load_function "$repo_root/scripts/incus_install.sh" install_dns_checker
    command() {
        [[ "$*" != '-v systemctl' ]] || return 1
        builtin command "$@"
    }
    wget() { fail 'optional systemd service must not download on OpenRC'; }
    download_file() { fail 'optional systemd service must not download on OpenRC'; }
    service_manager() { fail 'optional systemd service must not start on OpenRC'; }
    install_dns_checker || fail 'OpenRC must not fail on optional systemd DNS setup'
)
for distro in Fedora CentOS; do
    (
        SYSTEM=$distro epel_attempts=0
        load_function "$repo_root/scripts/incus_install.sh" setup_firewall
        command() {
            case "$*" in
                '-v apt'|'-v yum') return 1 ;;
                '-v dnf') return 0 ;;
            esac
            builtin command "$@"
        }
        install_package() {
            if [[ "$1" == epel-release ]]; then epel_attempts=$((epel_attempts + 1)); return 1; fi
        }
        service_manager() { :; }
        install_lsb_release() { return 1; }
        install_uidmap() { :; }
        setup_firewall || fail 'optional EPEL/lsb_release must not reject usable RPM hosts'
        if [[ "$distro" == Fedora ]]; then
            [[ "$epel_attempts" == 0 ]] || fail 'Fedora must not require the EPEL repository'
        else
            [[ "$epel_attempts" == 1 ]] || fail 'RHEL-family optional EPEL setup must remain available'
        fi
    )
done

# A minimal Debian host can install the Incus/LXD runtime without the
# dnsmasq executable that managed-network initialization invokes.  Keep the
# package-name mapping covered for both the Incus installer and the panel
# helper so this failure is caught before a real daemon init.
for installer in "$repo_root/scripts/incus_install.sh" "$repo_root/panel_scripts/panel_init.sh"; do
    load_function "$installer" install_dnsmasq
    for package_manager in apt non_apt; do
        (
            mock_dnsmasq=false
            installed_package=''
            PACKAGETYPE="$package_manager"
            command() {
                if [[ "$1" == -v && "$2" == dnsmasq ]]; then
                    $mock_dnsmasq
                    return
                fi
                # Keep the synthetic non-apt branch independent from the
                # Debian container that runs this test. Without this guard,
                # the host's real apt-get leaks into the mocked package
                # manager and makes the assertion depend on the test image.
                if [[ "$1" == -v && "$2" == apt-get && "$package_manager" != apt ]]; then
                    return 1
                fi
                if [[ "$package_manager" == apt && "$1" == -v && "$2" == apt-get ]]; then
                    return 0
                fi
                builtin command "$@"
            }
            install_package() {
                installed_package="$1"
                mock_dnsmasq=true
            }
            install_dnsmasq || fail "$installer/$package_manager must install dnsmasq"
            if [[ "$package_manager" == apt ]]; then
                [[ "$installed_package" == dnsmasq-base ]] || fail "$installer selected $installed_package instead of dnsmasq-base"
            else
                [[ "$installed_package" == dnsmasq ]] || fail "$installer selected $installed_package instead of dnsmasq"
            fi
        )
    done
done
printf 'Incus package/helper and sysctl compatibility checks passed (77 scenarios)\n'
