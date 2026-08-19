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
grep -Fq 'iptables -w -t nat -A POSTROUTING -s 192.0.2.0/31 -o eth0 -j MASQUERADE' <<< "$awg_smoke_config"
grep -Fq 'iptables -w -A FORWARD -i awg3axtest -j ACCEPT' <<< "$awg_smoke_config"

configure_panel_definition="$(declare -f configure_panel)"
main_definition="$(declare -f main)"
on_exit_definition="$(declare -f on_exit)"
save_credentials_definition="$(declare -f save_credentials)"
grep -Fq 'save_credentials' <<< "$configure_panel_definition"
grep -Fq 'mark_installation_complete' <<< "$main_definition"
grep -Fq '! -s "$STATE_FILE"' <<< "$main_definition"
grep -Fq 'CREDENTIALS_PRINTED' <<< "$on_exit_definition"
if grep -Fq 'rm -f -- "$STATE_FILE"' <<< "$save_credentials_definition"; then
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

printf 'Smoke tests passed.\n'
