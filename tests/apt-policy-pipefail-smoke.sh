#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/install.sh"

# More than a pipe buffer after Candidate makes early-exit consumers fail
# reliably under pipefail. Consumers must drain the complete policy output.
apt-cache() {
    printf '  Candidate: 3.1.20260906\n'
    local line
    for ((line = 0; line < 3000; line++)); do
        printf '     3.1.20260906 500 https://example.invalid/packages amd64 Packages\n'
    done
}
dpkg-query() { return 1; }

candidate="$(apt_package_candidate_version linux-headers-test)"
[[ "$candidate" == '3.1.20260906' ]]
updates="$(amneziawg_available_updates)"
[[ "$(printf '%s\n' "$updates" | wc -l)" -eq 3 ]]
grep -Fxq $'amneziawg\tnot-installed\t3.1.20260906' <<< "$updates"

apt-cache() { printf '  Candidate: (none)\n'; }
[[ -z "$(apt_package_candidate_version linux-headers-test)" ]]
[[ -z "$(amneziawg_available_updates)" ]]

printf 'APT policy pipefail regression passed\n'
