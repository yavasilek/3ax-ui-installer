#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/install.sh"

tag="$(fetch_latest_upstream_tag)"
version="$(normalize_xui_version "$tag")"
[[ -n "$version" ]]

asset_url="https://github.com/coinman-dev/3ax-ui/releases/download/$tag/x-ui-linux-amd64.tar.gz"
curl -fsSIL --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 10 --max-time 30 -o /dev/null "$asset_url"

printf '3AX-UI stable release smoke test passed: %s\n' "$tag"
