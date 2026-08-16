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

printf 'Smoke tests passed.\n'
