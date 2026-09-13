#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/install.sh"

assert_fails() {
    if "$@"; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

valid_ipv4 "185.105.226.75"
valid_ipv4 "8.8.8.8"
assert_fails valid_ipv4 "999.105.226.75"
assert_fails valid_ipv4 "not-an-ip"

valid_domain "185-105-226-75.sslip.io"
valid_domain "vpn.example.com"
assert_fails valid_domain "https://vpn.example.com"
assert_fails valid_domain "bad_domain.example.com"

[[ "$(select_amnezia_ppa_suite debian 11)" == "focal" ]]
[[ "$(select_amnezia_ppa_suite debian 12)" == "jammy" ]]
[[ "$(select_amnezia_ppa_suite debian 13)" == "noble" ]]
[[ "$(select_amnezia_ppa_suite ubuntu 22.04)" == "jammy" ]]
[[ "$(select_amnezia_ppa_suite ubuntu 24.04)" == "noble" ]]

legacy_sources=$'deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main\ndeb http://deb.debian.org/debian trixie main\n'
sanitized_sources="$(strip_legacy_amnezia_source_lines <<< "$legacy_sources")"
[[ "$sanitized_sources" == 'deb http://deb.debian.org/debian trixie main' ]]

repository_definition="$(write_amnezia_repository_definition noble amd64)"
grep -Fxq 'Suites: noble' <<< "$repository_definition"
grep -Fxq 'Architectures: amd64' <<< "$repository_definition"
grep -Fxq "Signed-By: $AMNEZIA_PPA_KEYRING" <<< "$repository_definition"

[[ "$(normalize_amneziawg_version 'amneziawg-tools v3.1.20260812')" == "3.1.20260812" ]]
[[ "$(normalize_amneziawg_version '3.1.20260906')" == "3.1.20260906" ]]
assert_fails normalize_amneziawg_version 'unknown'
amneziawg_version_supports_3_1 'v3.1.20260812'
assert_fails amneziawg_version_supports_3_1 'v3.0.20260805'

mapfile -t ubuntu_header_packages < <(ubuntu_kernel_header_package_names '6.8.0-35-generic')
[[ ${#ubuntu_header_packages[@]} -eq 2 ]]
[[ "${ubuntu_header_packages[0]}" == 'linux-headers-6.8.0-35' ]]
[[ "${ubuntu_header_packages[1]}" == 'linux-headers-6.8.0-35-generic' ]]
[[ "$(ubuntu_snapshot_package_url \
    20240605T000000Z main linux linux-headers-6.8.0-35 6.8.0-35.35 all)" == \
    'https://snapshot.ubuntu.com/ubuntu/20240605T000000Z/pool/main/l/linux/linux-headers-6.8.0-35_6.8.0-35.35_all.deb' ]]
[[ "$(ubuntu_snapshot_package_url \
    20240605T000000Z main linux linux-headers-6.8.0-35-generic 6.8.0-35.35 amd64)" == \
    'https://snapshot.ubuntu.com/ubuntu/20240605T000000Z/pool/main/l/linux/linux-headers-6.8.0-35-generic_6.8.0-35.35_amd64.deb' ]]
assert_fails ubuntu_kernel_header_package_names 'invalid kernel'
assert_fails ubuntu_snapshot_package_url invalid main linux package 1.0 amd64
assert_fails ubuntu_snapshot_package_url 20240605T000000Z '../bad' linux package 1.0 amd64
[[ "$(urlencode_path_component 'linux-headers-6.12.95+deb13-amd64')" == \
    'linux-headers-6.12.95%2Bdeb13-amd64' ]]
[[ "$(debian_snapshot_file_url 2193f987a83fd83c2a80eb247025e40ff513ac5a)" == \
    'https://snapshot.debian.org/file/2193f987a83fd83c2a80eb247025e40ff513ac5a' ]]
assert_fails debian_snapshot_file_url invalid

normalized_ports="$(printf '%s\n' 2222 22 invalid 22 0 65535 65536 | normalize_ssh_ports)"
[[ "$normalized_ports" == "22,2222,65535" ]]

audit_fixture=$'The following packages are only half configured:\n grub-pc              GRand Unified Bootloader\n'
mapfile -t parsed_audit_packages < <(audit_package_names <<< "$audit_fixture")
[[ ${#parsed_audit_packages[@]} -eq 1 ]]
[[ "${parsed_audit_packages[0]}" == "grub-pc" ]]

audit_fixture=$'The following packages are only half configured:\n grub-pc              GRand Unified Bootloader\n linux-image-test     Linux image\n'
mapfile -t parsed_audit_packages < <(audit_package_names <<< "$audit_fixture")
[[ ${#parsed_audit_packages[@]} -eq 2 ]]

audit_packages_are_amneziawg amneziawg-dkms amneziawg-tools
assert_fails audit_packages_are_amneziawg amneziawg-dkms grub-pc

valid_awg_interface_name awg0
valid_awg_interface_name awg-test.1
assert_fails valid_awg_interface_name 'awg interface'
assert_fails valid_awg_interface_name 'this-interface-name-is-too-long'

valid_udp_port 30526
valid_udp_port 443
valid_udp_port 65535
assert_fails valid_udp_port 0
assert_fails valid_udp_port 65536
assert_fails valid_udp_port invalid

[[ "$(normalize_xui_version 'v1.6.5')" == "1.6.5" ]]
[[ "$(normalize_xui_version '3AX-UI v1.7.0')" == "1.7.0" ]]
assert_fails normalize_xui_version "not-a-version"
version_is_older "1.6.5" "1.7.0"
assert_fails version_is_older "1.7.0" "1.7.0"
assert_fails version_is_older "1.8.0" "1.7.0"

load_credentials_file <(printf '%s\n' \
    'URL: https://185-105-226-75.sslip.io:50409/4799d94d0547a1a6f1fa640c2f87dbf7/' \
    'Username: admin_test' \
    'Password: test-password')
[[ "$DOMAIN" == "185-105-226-75.sslip.io" ]]
[[ "$PANEL_PORT" == "50409" ]]
[[ "$WEB_PATH" == "4799d94d0547a1a6f1fa640c2f87dbf7" ]]
[[ "$PANEL_USERNAME" == "admin_test" ]]
[[ "$PANEL_PASSWORD" == "test-password" ]]

awg_compatibility_sql="$(write_awg_ipv4_client_compatibility_sql)"
grep -Fq "CREATE TRIGGER IF NOT EXISTS $AWG_IPV4_INSERT_TRIGGER" <<< "$awg_compatibility_sql"
grep -Fq "CREATE TRIGGER IF NOT EXISTS $AWG_IPV4_UPDATE_TRIGGER" <<< "$awg_compatibility_sql"
grep -Fq "client_allowed_ips = '0.0.0.0/0'" <<< "$awg_compatibility_sql"
grep -Fq "COALESCE(ipv6_enabled, 0) = 0" <<< "$awg_compatibility_sql"
[[ "$(AWG_PORT=443 choose_mobile_awg_port 443)" == "443" ]]

python_bin=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' >/dev/null 2>&1; then
    python_bin="python3"
elif command -v python >/dev/null 2>&1 && python -c 'import sqlite3' >/dev/null 2>&1; then
    python_bin="python"
fi
if [[ -n "$python_bin" ]]; then
    AWG_COMPATIBILITY_SQL="$awg_compatibility_sql" "$python_bin" - <<'PY'
import os
import sqlite3

db = sqlite3.connect(":memory:")
db.executescript(
    """
    CREATE TABLE awg_servers (id INTEGER PRIMARY KEY, ipv6_enabled numeric);
    CREATE TABLE awg_clients (
        id INTEGER PRIMARY KEY,
        server_id INTEGER,
        ipv6_address TEXT,
        client_allowed_ips TEXT
    );
    """
)
db.executescript(os.environ["AWG_COMPATIBILITY_SQL"])
db.execute("INSERT INTO awg_servers VALUES (1, 0)")
db.execute("INSERT INTO awg_servers VALUES (2, 1)")
db.execute("INSERT INTO awg_clients VALUES (1, 1, '', '0.0.0.0/0, ::/0')")
db.execute("INSERT INTO awg_clients VALUES (2, 2, '2001:db8::2/128', '0.0.0.0/0, ::/0')")
ipv4_only = db.execute("SELECT client_allowed_ips FROM awg_clients WHERE id=1").fetchone()[0]
dual_stack = db.execute("SELECT client_allowed_ips FROM awg_clients WHERE id=2").fetchone()[0]
assert ipv4_only == "0.0.0.0/0", ipv4_only
assert dual_stack == "0.0.0.0/0, ::/0", dual_stack
db.execute("UPDATE awg_clients SET client_allowed_ips='::/0, 0.0.0.0/0' WHERE id=1")
ipv4_only = db.execute("SELECT client_allowed_ips FROM awg_clients WHERE id=1").fetchone()[0]
assert ipv4_only == "0.0.0.0/0", ipv4_only
PY
fi

awg_smoke_config="$(write_awg_smoke_config test-private-key eth0 awg3axtest)"
grep -Fxq 'H1 = 5-1005' <<< "$awg_smoke_config"
grep -Fxq 'I1 = <r 32>' <<< "$awg_smoke_config"
grep -Fxq 'HeaderProtectionKey = test-private-key' <<< "$awg_smoke_config"
grep -Fxq 'ContentPaddingAddition = 10-100' <<< "$awg_smoke_config"
grep -Fxq 'RandomTrailers = on' <<< "$awg_smoke_config"
grep -Fxq 'DisableCookies = on' <<< "$awg_smoke_config"
grep -Fq 'iptables -w -t nat -A POSTROUTING -s 192.0.2.0/31 -o eth0 -j MASQUERADE' <<< "$awg_smoke_config"
grep -Fq 'iptables -w -A FORWARD -i awg3axtest -j ACCEPT' <<< "$awg_smoke_config"

configure_panel_definition="$(declare -f configure_panel)"
main_definition="$(declare -f main)"
on_exit_definition="$(declare -f on_exit)"
save_credentials_definition="$(declare -f save_credentials)"
http_challenge_definition="$(declare -f ensure_http_challenge_available)"
renewal_definition="$(declare -f configure_renewal)"
# These are intentional literal fragments from the sourced function bodies.
# shellcheck disable=SC2016
state_guard='! -s "$STATE_FILE"'
# shellcheck disable=SC2016
state_cleanup='rm -f -- "$STATE_FILE"'
grep -Fq 'save_credentials' <<< "$configure_panel_definition"
grep -Fq 'mark_installation_complete' <<< "$main_definition"
grep -Fq "$state_guard" <<< "$main_definition"
grep -Fq 'CREDENTIALS_PRINTED' <<< "$on_exit_definition"
grep -Fq 'maybe_update_upstream_panel' <<< "$main_definition"
grep -Fq 'rollback_panel_update' <<< "$(declare -f run_upstream_update)"
grep -Fq 'amneziawg_available_updates' <<< "$(declare -f install_amneziawg_stack)"
grep -Fq 'reload_amneziawg_module_if_needed' <<< "$(declare -f install_amneziawg_stack)"
grep -Fq 'ensure_running_kernel_headers' <<< "$(declare -f install_amneziawg_stack)"
grep -Fq 'validate_deb_identity' <<< "$(declare -f install_archived_ubuntu_kernel_headers)"
grep -Fq 'ubuntu_snapshot_locator' <<< "$(declare -f install_archived_ubuntu_kernel_headers)"
grep -Fq 'debian_snapshot_binary_version' <<< "$(declare -f install_archived_debian_kernel_headers)"
grep -Fq 'debian_snapshot_kernel_dependencies' <<< "$(declare -f install_archived_debian_kernel_headers)"
grep -Fq 'install_archived_debian_kernel_headers' <<< "$(declare -f ensure_running_kernel_headers)"
grep -Fq 'systemctl stop nginx.service' <<< "$http_challenge_definition"
grep -Fq 'restore_http_challenge_nginx' <<< "$http_challenge_definition"
grep -Fq 'stop-3ax-ui-nginx' <<< "$renewal_definition"
grep -Fq 'start-3ax-ui-nginx' <<< "$renewal_definition"
grep -Fq 'HTTP_CHALLENGE_NGINX_WAS_ACTIVE' <<< "$on_exit_definition"
if grep -Fq "$state_cleanup" <<< "$save_credentials_definition"; then
    printf 'Credentials must be saved before the resumable state is removed.\n' >&2
    exit 1
fi

mock_bin="$(mktemp -d)"
cleanup() {
    rm -rf -- "$mock_bin"
}
trap cleanup EXIT

printf '%s\n' '#!/usr/bin/env bash' 'printf "unfinished package state\\n"' > "$mock_bin/dpkg"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$mock_bin/apt-get"
chmod +x "$mock_bin/dpkg" "$mock_bin/apt-get"
if (PATH="$mock_bin:$PATH" check_package_manager_health >/dev/null 2>&1); then
    printf 'Expected package-manager health check to fail.\n' >&2
    exit 1
fi

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$mock_bin/dpkg"
PATH="$mock_bin:$PATH" check_package_manager_health

# Variables below intentionally expand later inside the generated mock scripts.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ -e "${MOCK_NGINX_ACTIVE:?}" ]]; then' \
    '    printf "LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\\n"' \
    'fi' > "$mock_bin/ss"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'service="${*: -1}"' \
    'case "${1:-}:$service" in' \
    '    is-active:nginx.service) [[ -e "${MOCK_NGINX_ACTIVE:?}" ]] ;;' \
    '    stop:nginx.service) rm -f -- "$MOCK_NGINX_ACTIVE"; : > "$MOCK_NGINX_STOPPED" ;;' \
    '    start:nginx.service) : > "$MOCK_NGINX_ACTIVE"; : > "$MOCK_NGINX_STARTED" ;;' \
    '    *) exit 1 ;;' \
    'esac' > "$mock_bin/systemctl"
printf '%s\n' '#!/usr/bin/env bash' 'printf "Status: inactive\\n"' > "$mock_bin/ufw"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$mock_bin/firewall-cmd"
chmod +x "$mock_bin/ss" "$mock_bin/systemctl" "$mock_bin/ufw" "$mock_bin/firewall-cmd"

export MOCK_NGINX_ACTIVE="$mock_bin/nginx-active"
export MOCK_NGINX_STOPPED="$mock_bin/nginx-stopped"
export MOCK_NGINX_STARTED="$mock_bin/nginx-started"
: > "$MOCK_NGINX_ACTIVE"
HTTP_CHALLENGE_NGINX_WAS_ACTIVE=0
PATH="$mock_bin:$PATH"
ensure_http_challenge_available
[[ "$HTTP_CHALLENGE_NGINX_WAS_ACTIVE" -eq 1 ]]
[[ -e "$MOCK_NGINX_STOPPED" ]]
[[ ! -e "$MOCK_NGINX_ACTIVE" ]]
restore_http_challenge_nginx
[[ "$HTTP_CHALLENGE_NGINX_WAS_ACTIVE" -eq 0 ]]
[[ -e "$MOCK_NGINX_STARTED" ]]
[[ -e "$MOCK_NGINX_ACTIVE" ]]

printf 'Smoke tests passed.\n'
