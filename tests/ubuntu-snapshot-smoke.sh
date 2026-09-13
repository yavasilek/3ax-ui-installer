#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/install.sh"

VERSION_CODENAME=noble
kernel_version="6.8.0-35-generic"
architecture="amd64"
image_version="6.8.0-35.35"
base_package="linux-headers-6.8.0-35"
flavor_package="linux-headers-$kernel_version"
locator="$(ubuntu_snapshot_locator "$flavor_package" "$image_version" "$architecture")"
IFS=$'\t' read -r component source_package snapshot_id header_version <<< "$locator"

[[ "$component" == "main" ]]
[[ "$source_package" == "linux" ]]
[[ "$snapshot_id" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
[[ "$header_version" == "$image_version" ]]

base_url="$(ubuntu_snapshot_package_url \
    "$snapshot_id" "$component" "$source_package" \
    "$base_package" "$header_version" all)"
flavor_url="$(ubuntu_snapshot_package_url \
    "$snapshot_id" "$component" "$source_package" \
    "$flavor_package" "$header_version" "$architecture")"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT

curl -fsSL --retry 3 -o "$temp_dir/base.deb" "$base_url"
curl -fsSL --retry 3 -o "$temp_dir/flavor.deb" "$flavor_url"
validate_deb_identity "$temp_dir/base.deb" "$base_package" "$header_version" all
validate_deb_identity \
    "$temp_dir/flavor.deb" "$flavor_package" "$header_version" "$architecture"

printf 'Ubuntu Snapshot headers smoke test passed.\n'
