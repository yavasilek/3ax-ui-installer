#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/install.sh"

kernel_version="6.12.95+deb13-amd64"
architecture="amd64"
image_version="6.12.95-1"
headers_package="linux-headers-$kernel_version"
headers_version="$(debian_snapshot_binary_version "$headers_package" "$image_version")"
[[ "$headers_version" == "$image_version" ]]

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT

download_and_validate() {
    local package="$1"
    local preferred_version="$2"
    local file="$3"
    local version
    local package_architecture
    local sha1
    local locator
    local url

    version="$(debian_snapshot_binary_version "$package" "$preferred_version")"
    locator="$(debian_snapshot_binary_locator "$package" "$version" "$architecture")"
    IFS=$'\t' read -r package_architecture sha1 <<< "$locator"
    url="$(debian_snapshot_file_url "$sha1")"
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$file" "$url"
    validate_deb_identity "$file" "$package" "$version" "$package_architecture"
}

headers_file="$temp_dir/headers.deb"
download_and_validate "$headers_package" "$headers_version" "$headers_file"

mapfile -t dependencies < <(debian_snapshot_kernel_dependencies "$headers_file")
printf '%s\n' "${dependencies[@]}" | grep -Fxq $'linux-headers-6.12.95+deb13-common\t6.12.95-1'
printf '%s\n' "${dependencies[@]}" | grep -Fxq $'linux-kbuild-6.12.95+deb13\t'

index=0
for dependency_line in "${dependencies[@]}"; do
    IFS=$'\t' read -r dependency dependency_version <<< "$dependency_line"
    index=$((index + 1))
    download_and_validate \
        "$dependency" "${dependency_version:-$headers_version}" "$temp_dir/dependency-$index.deb"
done

printf 'Debian Snapshot headers smoke test passed.\n'
