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
