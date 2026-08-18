#!/usr/bin/env bash

set -Eeuo pipefail

readonly UPSTREAM_INSTALL_URL="https://raw.githubusercontent.com/coinman-dev/3ax-ui/main/install.sh"
readonly XUI_BIN="/usr/local/x-ui/x-ui"
readonly XUI_DB="/etc/x-ui/x-ui.db"
readonly CREDENTIALS_FILE="/root/3ax-ui-credentials.txt"
readonly STATE_FILE="/root/.3ax-ui-installer-state"
readonly AWG_CONFIG_DIR="/etc/amnezia/amneziawg"
readonly AMNEZIA_PPA_FINGERPRINT="75C9DD72C799870E310542E24166F2C257290828"
readonly AMNEZIA_PPA_KEYRING="/usr/share/keyrings/3ax-ui-amnezia-ppa.gpg"
readonly AMNEZIA_PPA_SOURCE="/etc/apt/sources.list.d/3ax-ui-amnezia.sources"

UPSTREAM_SCRIPT=""
UPSTREAM_LOG=""
AWG_REPAIR_PENDING=0

green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
plain='\033[0m'

info() {
    printf "${green}==>${plain} %s\n" "$*"
}

warn() {
    printf "${yellow}Warning:${plain} %s\n" "$*" >&2
}

die() {
    printf "${red}Error:${plain} %s\n" "$*" >&2
    exit 1
}

on_exit() {
    local exit_code=$?

    if [[ -n "$UPSTREAM_SCRIPT" && -f "$UPSTREAM_SCRIPT" ]]; then
        rm -f -- "$UPSTREAM_SCRIPT"
    fi

    if [[ $exit_code -eq 0 ]]; then
        if [[ -n "$UPSTREAM_LOG" && -f "$UPSTREAM_LOG" ]]; then
            rm -f -- "$UPSTREAM_LOG"
        fi
    elif [[ -n "$UPSTREAM_LOG" && -f "$UPSTREAM_LOG" ]]; then
        printf "Installation log: %s\n" "$UPSTREAM_LOG" >&2
    fi
}
trap on_exit EXIT

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Run this command as root."
}

load_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect the operating system."
    # shellcheck source=/dev/null
    source /etc/os-release

    case "${ID:-}" in
        debian)
            local debian_major="${VERSION_ID%%.*}"
            [[ "$debian_major" =~ ^[0-9]+$ && "$debian_major" -ge 11 ]] || \
                die "Debian 11 or newer is required."
            ;;
        ubuntu)
            dpkg --compare-versions "${VERSION_ID:-0}" ge "22.04" || \
                die "Ubuntu 22.04 or newer is required."
            ;;
        *)
            die "Supported systems: Debian 11+ and Ubuntu 22.04+."
            ;;
    esac

    [[ -d /run/systemd/system ]] || die "systemd is required."

    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) die "Supported CPU architectures: amd64 and arm64." ;;
    esac
}

install_prerequisites() {
    local -a missing_packages=()

    command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
    command -v certbot >/dev/null 2>&1 || missing_packages+=(certbot)
    if ! command -v ip >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
        missing_packages+=(iproute2)
    fi
    command -v openssl >/dev/null 2>&1 || missing_packages+=(openssl)
    command -v gpg >/dev/null 2>&1 || missing_packages+=(gnupg)
    command -v fail2ban-client >/dev/null 2>&1 || missing_packages+=(fail2ban)
    command -v nft >/dev/null 2>&1 || missing_packages+=(nftables)
    command -v iptables >/dev/null 2>&1 || missing_packages+=(iptables)
    command -v sqlite3 >/dev/null 2>&1 || missing_packages+=(sqlite3)
    command -v ndppd >/dev/null 2>&1 || missing_packages+=(ndppd)
    if ! dpkg-query -W -f='${Status}' python3-systemd 2>/dev/null | grep -q 'ok installed'; then
        missing_packages+=(python3-systemd)
    fi
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing_packages+=(ca-certificates)

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        info "Prerequisites are already installed"
        return
    fi

    info "Installing prerequisites: ${missing_packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "${missing_packages[@]}"
}

select_amnezia_ppa_suite() {
    local os_id="$1"
    local version="$2"
    local major="${version%%.*}"

    [[ "$major" =~ ^[0-9]+$ ]] || return 1

    case "$os_id" in
        debian)
            if [[ "$major" -ge 13 ]]; then
                printf 'noble\n'
            elif [[ "$major" -eq 12 ]]; then
                printf 'jammy\n'
            else
                printf 'focal\n'
            fi
            ;;
        ubuntu)
            if [[ "$major" -ge 24 ]]; then
                printf 'noble\n'
            else
                printf 'jammy\n'
            fi
            ;;
        *) return 1 ;;
    esac
}

strip_legacy_amnezia_source_lines() {
    sed '\#ppa.launchpadcontent.net/amnezia/ppa/ubuntu#d'
}

sanitize_legacy_amnezia_sources() {
    local source_file
    local temp_file
    local backup_dir=""
    local -a source_files=(/etc/apt/sources.list)

    shopt -s nullglob
    source_files+=(/etc/apt/sources.list.d/*.list)
    shopt -u nullglob

    for source_file in "${source_files[@]}"; do
        [[ -f "$source_file" ]] || continue
        grep -q 'ppa.launchpadcontent.net/amnezia/ppa/ubuntu' "$source_file" || continue

        if [[ -z "$backup_dir" ]]; then
            backup_dir="$(mktemp -d /root/3ax-ui-amnezia-source-backup.XXXXXX)"
            chmod 700 "$backup_dir"
        fi
        cp -a -- "$source_file" "$backup_dir/$(basename "$source_file")"

        temp_file="$(mktemp "$(dirname "$source_file")/.3ax-ui-amnezia.XXXXXX")"
        strip_legacy_amnezia_source_lines < "$source_file" > "$temp_file"
        chown --reference="$source_file" "$temp_file"
        chmod --reference="$source_file" "$temp_file"
        mv -f -- "$temp_file" "$source_file"
    done

    if [[ -n "$backup_dir" ]]; then
        info "Replaced legacy Amnezia PPA entries (backup: $backup_dir)"
    fi
}

write_amnezia_repository_definition() {
    local suite="$1"
    local architecture="$2"

    printf '%s\n' \
        'Types: deb' \
        'URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu' \
        "Suites: $suite" \
        'Components: main' \
        "Architectures: $architecture" \
        "Signed-By: $AMNEZIA_PPA_KEYRING"
}

configure_amnezia_repository() {
    local suite
    local architecture
    local key_file
    local keyring_file
    local source_file
    local fingerprint

    suite="$(select_amnezia_ppa_suite "${ID:-}" "${VERSION_ID:-}")" || \
        die "Cannot select an AmneziaWG package repository."
    architecture="$(dpkg --print-architecture)"
    [[ "$architecture" == "amd64" || "$architecture" == "arm64" ]] || \
        die "The AmneziaWG repository does not support architecture $architecture."

    key_file="$(mktemp /tmp/3ax-ui-amnezia-key.XXXXXX)"
    keyring_file="$(mktemp /tmp/3ax-ui-amnezia-keyring.XXXXXX)"
    source_file="$(mktemp /tmp/3ax-ui-amnezia-source.XXXXXX)"

    if ! curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AMNEZIA_PPA_FINGERPRINT}" \
        -o "$key_file"; then
        rm -f -- "$key_file" "$keyring_file" "$source_file"
        die "Cannot download the official Amnezia PPA signing key."
    fi

    fingerprint="$(gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
    if [[ "$fingerprint" != "$AMNEZIA_PPA_FINGERPRINT" ]]; then
        rm -f -- "$key_file" "$keyring_file" "$source_file"
        die "The downloaded Amnezia PPA signing key has an unexpected fingerprint."
    fi

    gpg --batch --yes --dearmor --output "$keyring_file" "$key_file"
    write_amnezia_repository_definition "$suite" "$architecture" > "$source_file"
    install -m 0644 "$keyring_file" "$AMNEZIA_PPA_KEYRING"
    install -m 0644 "$source_file" "$AMNEZIA_PPA_SOURCE"
    rm -f -- "$key_file" "$keyring_file" "$source_file"

    info "Configured the signed Amnezia PPA ($suite, $architecture)"
}

amneziawg_is_ready() {
    local private_key
    local public_key
    local test_interface="awg3ax$$"

    command -v awg >/dev/null 2>&1 || return 1
    command -v awg-quick >/dev/null 2>&1 || return 1
    modprobe amneziawg >/dev/null 2>&1 || return 1

    private_key="$(awg genkey 2>/dev/null)"
    [[ -n "$private_key" ]] || return 1
    public_key="$(printf '%s\n' "$private_key" | awg pubkey 2>/dev/null)"
    [[ -n "$public_key" ]] || return 1

    if ! ip link add "$test_interface" type amneziawg >/dev/null 2>&1; then
        return 1
    fi
    ip link del "$test_interface" >/dev/null 2>&1 || true
}

write_awg_smoke_config() {
    local private_key="$1"
    local external_interface="$2"
    local test_interface="$3"

    cat <<EOF
[Interface]
PrivateKey = $private_key
Address = 192.0.2.1/32
MTU = 1420
Jc = 4
Jmin = 40
Jmax = 90
S1 = 56
S2 = 88
S3 = 12
S4 = 8
H1 = 5-1005
H2 = 2005-3005
H3 = 4005-5005
H4 = 6005-7005
I1 = <r 32>
PostUp = iptables -w -t nat -A POSTROUTING -s 192.0.2.0/31 -o $external_interface -j MASQUERADE; iptables -w -A FORWARD -i $test_interface -j ACCEPT; iptables -w -A FORWARD -o $test_interface -j ACCEPT; sysctl -q -w net.ipv4.ip_forward=1
PostDown = iptables -w -t nat -D POSTROUTING -s 192.0.2.0/31 -o $external_interface -j MASQUERADE; iptables -w -D FORWARD -i $test_interface -j ACCEPT; iptables -w -D FORWARD -o $test_interface -j ACCEPT
EOF
}

cleanup_awg_smoke() {
    local config_file="$1"
    local test_interface="$2"
    local external_interface="$3"
    local test_dir

    if [[ -s "$config_file" ]] && command -v awg-quick >/dev/null 2>&1; then
        awg-quick down "$config_file" >/dev/null 2>&1 || true
    fi
    ip link del "$test_interface" >/dev/null 2>&1 || true
    iptables -w -t nat -D POSTROUTING -s 192.0.2.0/31 -o "$external_interface" -j MASQUERADE >/dev/null 2>&1 || true
    iptables -w -D FORWARD -i "$test_interface" -j ACCEPT >/dev/null 2>&1 || true
    iptables -w -D FORWARD -o "$test_interface" -j ACCEPT >/dev/null 2>&1 || true
    rm -f -- "$config_file"
    test_dir="$(dirname "$config_file")"
    rmdir -- "$test_dir" >/dev/null 2>&1 || true
}

amneziawg_server_smoke_test() {
    local private_key
    local external_interface
    local test_interface="awg3ax$$"
    local test_dir
    local config_file
    local output

    command -v iptables >/dev/null 2>&1 || return 1
    external_interface="$(ip -4 route show default 2>/dev/null | awk '$1 == "default" {print $5; exit}')"
    [[ "$external_interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1

    private_key="$(awg genkey 2>/dev/null)"
    [[ -n "$private_key" ]] || return 1
    test_dir="$(mktemp -d /tmp/3ax-ui-awg-smoke.XXXXXX)"
    config_file="$test_dir/$test_interface.conf"
    write_awg_smoke_config "$private_key" "$external_interface" "$test_interface" > "$config_file"
    chmod 600 "$config_file"

    if ! output="$(awg-quick up "$config_file" 2>&1)"; then
        printf '%s\n' "$output" >&2
        cleanup_awg_smoke "$config_file" "$test_interface" "$external_interface"
        return 1
    fi
    if ! awg show "$test_interface" >/dev/null 2>&1; then
        cleanup_awg_smoke "$config_file" "$test_interface" "$external_interface"
        return 1
    fi
    if ! output="$(awg-quick down "$config_file" 2>&1)"; then
        printf '%s\n' "$output" >&2
        cleanup_awg_smoke "$config_file" "$test_interface" "$external_interface"
        return 1
    fi

    cleanup_awg_smoke "$config_file" "$test_interface" "$external_interface"
}

install_amneziawg_stack() {
    local kernel_version
    local headers_package

    if [[ "$AWG_REPAIR_PENDING" -eq 0 ]] && \
        amneziawg_is_ready && amneziawg_server_smoke_test; then
        info "AmneziaWG passed the full AWG 2.0 server startup test"
        return
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required to repair AmneziaWG."
    command -v gpg >/dev/null 2>&1 || die "gpg is required to repair AmneziaWG."

    sanitize_legacy_amnezia_sources
    configure_amnezia_repository

    kernel_version="$(uname -r)"
    headers_package="linux-headers-${kernel_version}"
    info "Installing AmneziaWG tools and DKMS module for kernel $kernel_version"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --reinstall \
        build-essential \
        dkms \
        "$headers_package" \
        iptables \
        ndppd \
        sqlite3 \
        amneziawg \
        amneziawg-dkms \
        amneziawg-tools

    dkms autoinstall -k "$kernel_version"
    depmod -a "$kernel_version"
    printf 'amneziawg\n' > /etc/modules-load.d/amneziawg.conf

    if ! amneziawg_is_ready || ! amneziawg_server_smoke_test; then
        dkms status >&2 || true
        modinfo amneziawg >&2 || true
        die "AmneziaWG was installed but a complete AWG 2.0 server could not be started."
    fi

    info "AmneziaWG passed the full AWG 2.0 server startup test"
}

normalize_ssh_ports() {
    awk '$1 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {print $1}' \
        | sort -nu \
        | paste -sd, -
}

detect_ssh_ports() {
    {
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            awk '{print $4}' <<< "$SSH_CONNECTION"
        fi

        if command -v sshd >/dev/null 2>&1; then
            sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
        fi

        if command -v ss >/dev/null 2>&1; then
            ss -H -ltnp 2>/dev/null | awk '
                /"sshd"/ {
                    address = $4
                    sub(/^.*:/, "", address)
                    print address
                }
            ' || true
        fi
    } | normalize_ssh_ports
}

restore_fail2ban_jail() {
    local jail_file="$1"
    local backup_file="$2"

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        cp -a -- "$backup_file" "$jail_file"
    else
        rm -f -- "$jail_file"
    fi
}

configure_fail2ban_ssh() {
    local ssh_ports
    local jail_file="/etc/fail2ban/jail.d/3ax-ui-ssh.local"
    local temp_file
    local backup_file=""
    local config_output

    ssh_ports="$(detect_ssh_ports)"
    [[ -n "$ssh_ports" ]] || die "Cannot determine the SSH port for Fail2Ban."

    temp_file="$(mktemp /tmp/3ax-ui-fail2ban.XXXXXX)"
    chmod 600 "$temp_file"
    {
        printf '%s\n' \
            '[sshd]' \
            'enabled = true' \
            'backend = systemd' \
            'mode = normal' \
            "port = $ssh_ports" \
            'maxretry = 5' \
            'findtime = 10m' \
            'bantime = 1h' \
            'bantime.increment = true' \
            'bantime.maxtime = 1d' \
            'usedns = no' \
            'banaction = nftables[type=multiport]'
    } > "$temp_file"

    mkdir -p /etc/fail2ban/jail.d
    if [[ -f "$jail_file" ]]; then
        backup_file="$(mktemp /tmp/3ax-ui-fail2ban-backup.XXXXXX)"
        cp -a -- "$jail_file" "$backup_file"
    fi
    install -m 0644 "$temp_file" "$jail_file"
    rm -f -- "$temp_file"

    if ! config_output="$(fail2ban-client -t 2>&1)"; then
        restore_fail2ban_jail "$jail_file" "$backup_file"
        rm -f -- "$backup_file"
        printf '%s\n' "$config_output" >&2
        die "Fail2Ban rejected the generated SSH jail; the previous configuration was restored."
    fi

    if ! systemctl enable fail2ban.service >/dev/null 2>&1 || \
        ! systemctl restart fail2ban.service >/dev/null 2>&1; then
        restore_fail2ban_jail "$jail_file" "$backup_file"
        rm -f -- "$backup_file"
        systemctl restart fail2ban.service >/dev/null 2>&1 || true
        systemctl status --no-pager fail2ban.service >&2 || true
        die "Fail2Ban could not start; the previous configuration was restored."
    fi

    for _ in {1..20}; do
        if fail2ban-client ping >/dev/null 2>&1 && \
            fail2ban-client status sshd >/dev/null 2>&1; then
            rm -f -- "$backup_file"
            info "Fail2Ban protects SSH on port(s): $ssh_ports"
            return
        fi
        sleep 1
    done

    restore_fail2ban_jail "$jail_file" "$backup_file"
    rm -f -- "$backup_file"
    systemctl restart fail2ban.service >/dev/null 2>&1 || true
    journalctl -u fail2ban.service -n 30 --no-pager >&2 || true
    die "The Fail2Ban sshd jail did not become active; the previous configuration was restored."
}

print_disk_diagnostics() {
    local root_source=""
    local boot_device=""
    local device_path
    local device_name
    local device_type
    local sectors
    local model

    if command -v findmnt >/dev/null 2>&1; then
        root_source="$(findmnt -no SOURCE / 2>/dev/null || true)"
    fi
    if [[ -z "$root_source" && -r /proc/self/mounts ]]; then
        root_source="$(awk '$2 == "/" {print $1; exit}' /proc/self/mounts)"
    fi
    if command -v grub-probe >/dev/null 2>&1; then
        boot_device="$(grub-probe --target=device /boot 2>/dev/null || true)"
    fi

    printf '\nRead-only disk diagnostics:\n' >&2
    printf 'Root filesystem: %s\n' "${root_source:-unknown}" >&2
    printf 'GRUB /boot device: %s\n' "${boot_device:-unknown}" >&2

    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL >&2 || true
    else
        printf '\nBlock devices from /sys/class/block (size is in 512-byte sectors):\n' >&2
        printf '%-16s %-10s %-14s %s\n' 'NAME' 'TYPE' 'SECTORS' 'MODEL' >&2
        for device_path in /sys/class/block/*; do
            [[ -e "$device_path" ]] || continue
            device_name="${device_path##*/}"
            if [[ -f "$device_path/partition" ]]; then
                device_type="partition"
            else
                device_type="disk"
            fi
            sectors="$(cat "$device_path/size" 2>/dev/null || printf '?')"
            model="$(tr -s ' ' < "$device_path/device/model" 2>/dev/null || true)"
            printf '%-16s %-10s %-14s %s\n' "$device_name" "$device_type" "$sectors" "$model" >&2
        done
    fi

    if [[ -d /dev/disk/by-id ]]; then
        printf '\nCurrent /dev/disk/by-id links:\n' >&2
        ls -l /dev/disk/by-id 2>/dev/null >&2 || true
    fi

    if command -v debconf-show >/dev/null 2>&1; then
        printf '\nSaved grub-pc install-device setting:\n' >&2
        debconf-show grub-pc 2>/dev/null | grep 'grub-pc/install_devices' >&2 || true
    fi
}

audit_package_names() {
    awk '/^ [[:alnum:]][^[:space:]]*[[:space:]]/ {print $1}'
}

audit_packages_are_amneziawg() {
    local package

    [[ $# -gt 0 ]] || return 1
    for package in "$@"; do
        case "$package" in
            amneziawg|amneziawg-dkms|amneziawg-tools) ;;
            *) return 1 ;;
        esac
    done
}

detect_grub_install_disk() {
    local boot_device
    local boot_real
    local boot_name
    local boot_sys_path
    local parent_sys_path
    local disk_name
    local disk_path
    local drive_hint
    local hinted_disk
    local read_only
    local removable
    local sectors

    command -v grub-probe >/dev/null 2>&1 || return 1
    boot_device="$(grub-probe --target=device /boot 2>/dev/null || true)"
    [[ "$boot_device" == /dev/* && -b "$boot_device" ]] || return 1

    boot_real="$(readlink -f "$boot_device" 2>/dev/null || true)"
    [[ "$boot_real" == /dev/* && -b "$boot_real" ]] || return 1
    boot_name="${boot_real##*/}"
    boot_sys_path="/sys/class/block/$boot_name"
    [[ -e "$boot_sys_path" ]] || return 1

    if [[ -f "$boot_sys_path/partition" ]]; then
        parent_sys_path="$(dirname "$(readlink -f "$boot_sys_path")")"
        disk_name="${parent_sys_path##*/}"
    else
        disk_name="$boot_name"
    fi

    case "$disk_name" in
        dm-*|loop*|md*|nbd*|ram*|sr*|zram*) return 1 ;;
    esac

    disk_path="/dev/$disk_name"
    [[ -b "$disk_path" ]] || return 1
    [[ -e "/sys/class/block/$disk_name" ]] || return 1
    [[ ! -f "/sys/class/block/$disk_name/partition" ]] || return 1

    read_only="$(cat "/sys/class/block/$disk_name/ro" 2>/dev/null || true)"
    removable="$(cat "/sys/class/block/$disk_name/removable" 2>/dev/null || true)"
    sectors="$(cat "/sys/class/block/$disk_name/size" 2>/dev/null || true)"
    [[ "$read_only" == "0" && "$removable" == "0" ]] || return 1
    [[ "$sectors" =~ ^[0-9]+$ && "$sectors" -gt 2097152 ]] || return 1

    drive_hint="$(grub-probe --target=drive /boot 2>/dev/null || true)"
    hinted_disk="$(sed -n 's#.*\(/dev/[^,)]*\).*#\1#p' <<< "$drive_hint")"
    if [[ -n "$hinted_disk" ]]; then
        [[ "$(readlink -f "$hinted_disk" 2>/dev/null || true)" == "$disk_path" ]] || return 1
    fi

    printf '%s\n' "$disk_path"
}

repair_unfinished_grub() {
    local disk
    local backup
    local remaining_audit

    print_disk_diagnostics
    disk="$(detect_grub_install_disk)" || \
        die "Cannot determine one safe whole boot disk for automatic grub-pc repair."

    backup="/root/grub-pc-debconf-before-3ax-$(date -u +%Y%m%dT%H%M%SZ).dat"
    if [[ -f /var/cache/debconf/config.dat ]]; then
        cp -a /var/cache/debconf/config.dat "$backup"
        chmod 600 "$backup"
    fi

    info "Repairing unfinished grub-pc configuration on verified disk $disk"
    printf '%s\n' \
        "grub-pc grub-pc/install_devices multiselect $disk" \
        "grub-pc grub-pc/install_devices_disks_changed multiselect $disk" \
        'grub-pc grub-pc/install_devices_empty boolean false' \
        | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive dpkg --configure grub-pc
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a

    remaining_audit="$(LC_ALL=C dpkg --audit 2>&1 || true)"
    if [[ -n "$remaining_audit" ]]; then
        printf '%s\n' "$remaining_audit" >&2
        die "dpkg still contains unfinished packages after grub-pc repair."
    fi

    info "grub-pc and dpkg were repaired successfully"
    if [[ -f "$backup" ]]; then
        printf 'Previous debconf state: %s\n' "$backup"
    fi
}

check_package_manager_health() {
    local audit_output
    local apt_check_output
    local -a audit_packages=()

    audit_output="$(LC_ALL=C dpkg --audit 2>&1 || true)"
    if [[ -n "$audit_output" ]]; then
        mapfile -t audit_packages < <(audit_package_names <<< "$audit_output")
        if [[ ${#audit_packages[@]} -eq 1 && "${audit_packages[0]}" == "grub-pc" ]]; then
            repair_unfinished_grub
        elif audit_packages_are_amneziawg "${audit_packages[@]}"; then
            AWG_REPAIR_PENDING=1
            warn "An unfinished AmneziaWG package installation will be repaired automatically."
        else
            printf '%s\n' "$audit_output" >&2
            die "dpkg contains unfinished packages that cannot be repaired safely by this installer."
        fi
    fi

    if [[ "$AWG_REPAIR_PENDING" -eq 0 ]] && ! apt_check_output="$(LC_ALL=C apt-get check 2>&1)"; then
        printf '%s\n' "$apt_check_output" >&2
        die "APT dependency checks failed. Repair APT/dpkg before installing 3AX-UI."
    fi
}

validate_host() {
    local kernel_version
    local oldest
    local memory_kb

    kernel_version="$(uname -r | cut -d- -f1)"
    oldest="$(printf '%s\n' "5.6" "$kernel_version" | sort -V | head -n1)"
    [[ "$oldest" == "5.6" ]] || die "Linux kernel 5.6 or newer is required."

    memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    if [[ -n "$memory_kb" && "$memory_kb" -lt 900000 ]]; then
        warn "The server has less than 1 GB RAM. Installation may fail."
    fi
}

valid_ipv4() {
    local ip="$1"
    local octet
    local octet_number
    local -a octets

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        octet_number=$((10#$octet))
        [[ "$octet_number" -ge 0 && "$octet_number" -le 255 ]] || return 1
    done
}

detect_public_ip() {
    local endpoint
    local candidate

    for endpoint in \
        "https://api4.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://4.ident.me"; do
        candidate="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
        if valid_ipv4 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

port_in_use() {
    local port="$1"
    ss -H -ltn 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)" && return 0
    ss -H -lun 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)" && return 0
    return 1
}

choose_panel_port() {
    local requested="${PANEL_PORT:-}"
    local candidate
    local random_hex
    local attempt

    if [[ -n "$requested" ]]; then
        [[ "$requested" =~ ^[0-9]+$ ]] || die "PANEL_PORT must be a number."
        [[ "$requested" -ge 1024 && "$requested" -le 65535 ]] || \
            die "PANEL_PORT must be between 1024 and 65535."
        port_in_use "$requested" && die "Port $requested is already in use."
        printf '%s\n' "$requested"
        return 0
    fi

    for ((attempt = 0; attempt < 128; attempt++)); do
        random_hex="$(openssl rand -hex 2)"
        candidate=$((20000 + (16#$random_hex % 40000)))
        if ! port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

save_state() {
    umask 077
    {
        printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP"
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'PANEL_PORT=%q\n' "$PANEL_PORT"
        printf 'PANEL_USERNAME=%q\n' "$PANEL_USERNAME"
        printf 'PANEL_PASSWORD=%q\n' "$PANEL_PASSWORD"
        printf 'WEB_PATH=%q\n' "$WEB_PATH"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_or_create_state() {
    if [[ -f "$STATE_FILE" ]]; then
        info "Resuming the interrupted installation"
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        return
    fi

    if [[ -e /usr/bin/x-ui || -e "$XUI_BIN" ]]; then
        die "x-ui is already installed but was not created by this installer. Refusing to overwrite it."
    fi

    PUBLIC_IP="$(detect_public_ip)" || die "Cannot detect the public IPv4 address."
    DOMAIN="${PANEL_DOMAIN:-${PUBLIC_IP//./-}.sslip.io}"
    valid_domain "$DOMAIN" || die "Invalid PANEL_DOMAIN: $DOMAIN"

    PANEL_PORT="$(choose_panel_port)" || die "Cannot find a free panel port."
    PANEL_USERNAME="${PANEL_USERNAME:-admin_$(openssl rand -hex 5)}"
    PANEL_PASSWORD="${PANEL_PASSWORD:-$(openssl rand -hex 20)}"
    WEB_PATH="$(openssl rand -hex 16)"

    [[ "$PANEL_USERNAME" =~ ^[A-Za-z0-9_.@-]{4,64}$ ]] || \
        die "PANEL_USERNAME contains unsupported characters or has an invalid length."
    [[ ${#PANEL_PASSWORD} -ge 16 ]] || die "PANEL_PASSWORD must contain at least 16 characters."

    save_state
}

verify_dns() {
    local resolved
    resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    grep -Fxq "$PUBLIC_IP" <<< "$resolved" || \
        die "$DOMAIN does not resolve to $PUBLIC_IP. Set PANEL_DOMAIN correctly or wait for DNS propagation."
}

open_firewall_port() {
    local port="$1"
    local protocol="$2"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${port}/${protocol}" >/dev/null
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null
        firewall-cmd --reload >/dev/null
    fi
}

valid_awg_interface_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

verify_awg_listen_port() {
    local interface_name="$1"
    local expected_port="$2"
    local actual_port

    actual_port="$(awg show "$interface_name" listen-port 2>/dev/null || true)"
    [[ "$actual_port" == "$expected_port" ]]
}

ensure_enabled_awg_runtime() {
    local server_row
    local enabled
    local interface_name
    local listen_port
    local config_file
    local start_output=""

    [[ -x "$XUI_BIN" && -s "$XUI_DB" ]] || return

    systemctl enable x-ui.service >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet x-ui.service; then
        systemctl restart x-ui.service || die "x-ui.service could not be started."
    fi

    server_row="$(sqlite3 -separator '|' "$XUI_DB" \
        "SELECT CASE WHEN enable THEN 1 ELSE 0 END, COALESCE(NULLIF(interface_name, ''), 'awg0'), listen_port FROM awg_servers ORDER BY id LIMIT 1;" \
        2>/dev/null || true)"
    [[ -n "$server_row" ]] || return
    IFS='|' read -r enabled interface_name listen_port <<< "$server_row"
    [[ "$enabled" == "1" ]] || return
    valid_awg_interface_name "$interface_name" || \
        die "The enabled AmneziaWG server has an unsafe interface name in the panel database."
    [[ "$listen_port" =~ ^[0-9]+$ && "$listen_port" -ge 1 && "$listen_port" -le 65535 ]] || \
        die "The enabled AmneziaWG server has an invalid UDP listen port."

    if awg show "$interface_name" >/dev/null 2>&1; then
        verify_awg_listen_port "$interface_name" "$listen_port" || \
            die "AmneziaWG is running on a different UDP port than the panel configuration."
        open_firewall_port "$listen_port" udp
        info "Enabled AmneziaWG server is running on $interface_name (UDP $listen_port)"
        return
    fi

    info "Restoring the enabled AmneziaWG server from the existing panel configuration"
    systemctl restart x-ui.service || die "x-ui.service could not be restarted to restore AmneziaWG."
    for _ in {1..20}; do
        if awg show "$interface_name" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if ! awg show "$interface_name" >/dev/null 2>&1; then
        config_file="$AWG_CONFIG_DIR/$interface_name.conf"
        [[ -s "$config_file" ]] || {
            journalctl -u x-ui.service -n 30 --no-pager >&2 || true
            die "3AX-UI did not generate the enabled AmneziaWG server configuration."
        }
        if ! start_output="$(awg-quick up "$config_file" 2>&1)"; then
            printf '%s\n' "$start_output" >&2
            journalctl -u x-ui.service -n 30 --no-pager >&2 || true
            die "The saved AmneziaWG server configuration could not be started. Client keys and settings were not changed."
        fi
    fi

    awg show "$interface_name" >/dev/null 2>&1 || \
        die "AmneziaWG reported a successful start but the interface is not available."
    verify_awg_listen_port "$interface_name" "$listen_port" || \
        die "AmneziaWG started on a different UDP port than the panel configuration."
    open_firewall_port "$listen_port" udp
    info "AmneziaWG was restored without changing clients or keys ($interface_name, UDP $listen_port)"
}

ensure_http_challenge_available() {
    if ss -H -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:80([[:space:]]|$)'; then
        die "TCP port 80 is already in use. This installer is intended for a clean VPS and needs port 80 for HTTPS."
    fi

    open_firewall_port 80 tcp
}

install_upstream_panel() {
    [[ -x "$XUI_BIN" ]] && return

    info "Installing the latest stable 3AX-UI (this can take several minutes)"
    UPSTREAM_SCRIPT="$(mktemp /tmp/3ax-ui-upstream.XXXXXX)"
    UPSTREAM_LOG="$(mktemp /tmp/3ax-ui-upstream-log.XXXXXX)"
    chmod 600 "$UPSTREAM_SCRIPT" "$UPSTREAM_LOG"
    curl -fsSL "$UPSTREAM_INSTALL_URL" -o "$UPSTREAM_SCRIPT"

    if [[ -n "${THREE_AX_VERSION:-}" ]]; then
        XUI_DEBUG_MODE=1 XUI_DEBUG_PORT="$PANEL_PORT" \
            bash "$UPSTREAM_SCRIPT" "$THREE_AX_VERSION" </dev/null >"$UPSTREAM_LOG" 2>&1 || {
                sed -E 's/(Username|Password):.*/\1: [REDACTED]/I' "$UPSTREAM_LOG" | tail -n 80 >&2
                die "The upstream 3AX-UI installer failed."
            }
    else
        XUI_DEBUG_MODE=1 XUI_DEBUG_PORT="$PANEL_PORT" \
            bash "$UPSTREAM_SCRIPT" </dev/null >"$UPSTREAM_LOG" 2>&1 || {
                sed -E 's/(Username|Password):.*/\1: [REDACTED]/I' "$UPSTREAM_LOG" | tail -n 80 >&2
                die "The upstream 3AX-UI installer failed."
            }
    fi

    [[ -x "$XUI_BIN" ]] || die "3AX-UI finished without installing the panel binary."
}

verify_amneziawg() {
    info "Checking AmneziaWG support"
    amneziawg_is_ready || \
        die "The AmneziaWG tools or kernel module failed the final runtime test."
}

obtain_certificate() {
    local cert_dir="/etc/letsencrypt/live/$DOMAIN"

    if [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] && \
        openssl x509 -checkend 86400 -noout -in "$cert_dir/fullchain.pem" >/dev/null 2>&1; then
        info "Using the existing valid TLS certificate"
        return
    fi

    ensure_http_challenge_available
    info "Obtaining a trusted HTTPS certificate for $DOMAIN"
    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --preferred-challenges http \
        --key-type rsa \
        --rsa-key-size 2048 \
        --cert-name "$DOMAIN" \
        -d "$DOMAIN"

    [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || \
        die "Certbot did not create the expected certificate files."
}

configure_renewal() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="$hook_dir/restart-3ax-ui"

    mkdir -p "$hook_dir"
    printf '%s\n' '#!/bin/sh' 'systemctl try-restart x-ui.service >/dev/null 2>&1 || true' > "$hook"
    chmod 755 "$hook"
    systemctl enable --now certbot.timer >/dev/null 2>&1 || \
        warn "certbot.timer could not be enabled; certificate renewal must be checked manually."
}

configure_panel() {
    local cert_dir="/etc/letsencrypt/live/$DOMAIN"

    info "Applying secure panel settings"
    systemctl stop x-ui.service >/dev/null 2>&1 || true

    "$XUI_BIN" setting \
        -username "$PANEL_USERNAME" \
        -password "$PANEL_PASSWORD" \
        -port "$PANEL_PORT" \
        -webBasePath "$WEB_PATH" \
        -listenIP "0.0.0.0" \
        -resetTwoFactor true >/dev/null

    "$XUI_BIN" cert \
        -webCert "$cert_dir/fullchain.pem" \
        -webCertKey "$cert_dir/privkey.pem" >/dev/null

    "$XUI_BIN" migrate >/dev/null
    systemctl enable --now x-ui.service >/dev/null
    systemctl restart x-ui.service
    open_firewall_port "$PANEL_PORT" tcp
}

verify_panel() {
    local url="https://${DOMAIN}:${PANEL_PORT}/${WEB_PATH}/"
    local status=""

    info "Verifying the installed panel"
    systemctl is-active --quiet x-ui.service || die "x-ui.service is not running."

    for _ in {1..20}; do
        status="$(curl -sS --max-time 5 \
            --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" \
            -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
            return
        fi
        sleep 1
    done

    die "The panel did not pass the local HTTPS check (last HTTP status: ${status:-none})."
}

save_credentials() {
    local url="https://${DOMAIN}:${PANEL_PORT}/${WEB_PATH}/"

    umask 077
    {
        printf 'URL: %s\n' "$url"
        printf 'Username: %s\n' "$PANEL_USERNAME"
        printf 'Password: %s\n' "$PANEL_PASSWORD"
    } > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    rm -f -- "$STATE_FILE"
}

print_credentials() {
    printf '\n'
    printf '%b\n' "${green}============================================${plain}"
    printf '%b\n' "${green}  3AX-UI installation completed${plain}"
    printf '%b\n' "${green}============================================${plain}"
    cat "$CREDENTIALS_FILE"
    printf '%b\n' "${green}============================================${plain}"
    printf 'Credentials are also stored in %s (root only).\n' "$CREDENTIALS_FILE"
    printf 'Change the username and password after the first login.\n'
}

main() {
    require_root
    load_os
    check_package_manager_health

    if [[ "$AWG_REPAIR_PENDING" -eq 1 ]]; then
        install_amneziawg_stack
        AWG_REPAIR_PENDING=0
        check_package_manager_health
        [[ "$AWG_REPAIR_PENDING" -eq 0 ]] || \
            die "dpkg still contains unfinished AmneziaWG packages after repair."
    fi

    sanitize_legacy_amnezia_sources
    install_prerequisites
    validate_host
    configure_fail2ban_ssh
    install_amneziawg_stack

    if [[ -x "$XUI_BIN" && -s "$CREDENTIALS_FILE" ]]; then
        ensure_enabled_awg_runtime
        print_credentials
        exit 0
    fi

    load_or_create_state
    verify_dns
    install_upstream_panel
    verify_amneziawg
    obtain_certificate
    configure_renewal
    configure_panel
    verify_panel
    ensure_enabled_awg_runtime
    save_credentials
    print_credentials
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
