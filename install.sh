#!/usr/bin/env bash

set -Eeuo pipefail

readonly UPSTREAM_INSTALL_URL="https://raw.githubusercontent.com/coinman-dev/3ax-ui/main/install.sh"
readonly XUI_BIN="/usr/local/x-ui/x-ui"
readonly CREDENTIALS_FILE="/root/3ax-ui-credentials.txt"
readonly STATE_FILE="/root/.3ax-ui-installer-state"

UPSTREAM_SCRIPT=""
UPSTREAM_LOG=""

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

print_disk_diagnostics() {
    printf '\nRead-only disk diagnostics:\n' >&2
    printf 'Root filesystem: ' >&2
    findmnt -no SOURCE / 2>/dev/null >&2 || printf 'unknown\n' >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL 2>/dev/null >&2 || true
}

check_package_manager_health() {
    local audit_output
    local apt_check_output

    audit_output="$(LC_ALL=C dpkg --audit 2>&1 || true)"
    if [[ -n "$audit_output" ]]; then
        printf '%s\n' "$audit_output" >&2
        print_disk_diagnostics

        if grep -qw 'grub-pc' <<< "$audit_output"; then
            printf '\nThe unfinished grub-pc setup must be repaired before installing 3AX-UI.\n' >&2
            printf 'Do not guess the boot disk. Use the diagnostics above, then run:\n\n' >&2
            printf '  DEBIAN_FRONTEND=dialog dpkg --configure grub-pc\n' >&2
            printf '  dpkg --configure -a\n' >&2
            printf '  dpkg --audit\n\n' >&2
            printf 'In the GRUB dialog select the current whole boot disk, not a partition.\n' >&2
        else
            printf '\nRepair unfinished packages with dpkg --configure -a, then rerun this installer.\n' >&2
        fi

        die "The Debian package database contains unfinished packages."
    fi

    if ! apt_check_output="$(LC_ALL=C apt-get check 2>&1)"; then
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
    command -v awg >/dev/null 2>&1 || \
        die "The awg utility is missing. See the upstream installation log and rerun this installer."
    modprobe amneziawg >/dev/null 2>&1 || \
        die "The AmneziaWG kernel module cannot be loaded. Check DKMS and Secure Boot, then rerun."
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

    if [[ -x "$XUI_BIN" && -s "$CREDENTIALS_FILE" ]]; then
        print_credentials
        exit 0
    fi

    load_os
    check_package_manager_health
    install_prerequisites
    validate_host
    load_or_create_state
    verify_dns
    install_upstream_panel
    verify_amneziawg
    obtain_certificate
    configure_renewal
    configure_panel
    verify_panel
    save_credentials
    print_credentials
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
