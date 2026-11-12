#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/install.sh"

# Replace only the filesystem precondition with harmless existing fixtures;
# every service/tool operation below is mocked. No real VPN is managed.
definition="$(declare -f ensure_enabled_awg_runtime)"
# Match the literal variable references in the function body.
# shellcheck disable=SC2016
definition="${definition//'"$XUI_BIN"'/'"/bin/bash"'}"
# shellcheck disable=SC2016
definition="${definition//'"$XUI_DB"'/'"/etc/os-release"'}"
eval "$definition"
systemctl() {
    case "$1" in
        enable|is-active) return 0 ;;
        *) printf 'Unexpected service mutation\n' >&2; return 87 ;;
    esac
}
sqlite3_clean() { printf '%s\n' "$test_server_row"; }
awg() { printf 'Disabled server must not invoke awg\n' >&2; return 88; }

test_server_row='0|awg0|30526'
ensure_enabled_awg_runtime
test_server_row=''
ensure_enabled_awg_runtime
printf 'Disabled/missing AWG server no-op regression passed\n'
