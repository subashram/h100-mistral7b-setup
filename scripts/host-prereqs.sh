#!/usr/bin/env bash
# =============================================================================
# Host prerequisites — check, report, and optionally install required software
# Supported install path: Ubuntu with apt
# =============================================================================
set -euo pipefail

MODE="${1:-check}"     # check | report | install
EXPECTED_GPUS="${EXPECTED_GPUS:-8}"
MIN_DISK_GB="${MIN_DISK_GB:-100}"
INSTALL_OPTIONAL="${INSTALL_OPTIONAL:-0}"   # set to 1 to install optional tools

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
REPORT_LINES=()

is_root() {
    [ "$(id -u)" -eq 0 ]
}

run_as_root() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    REPORT_LINES+=("PASS|$1")
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    REPORT_LINES+=("WARN|$1")
    WARN_COUNT=$((WARN_COUNT + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    REPORT_LINES+=("FAIL|$1")
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

require_supported_os() {
    if [ ! -f /etc/os-release ]; then
        echo "Unsupported OS: /etc/os-release not found" >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu) ;;
        *)
            echo "Install mode currently supports Ubuntu only (detected '${ID:-unknown}')" >&2
            exit 1
            ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_command() {
    local command_name="$1"
    local label="$2"
    if command_exists "$command_name"; then
        log_pass "$label is installed"
    else
        log_fail "$label is missing"
    fi
}

check_service_active() {
    local service_name="$1"
    local label="$2"
    if command_exists systemctl && systemctl is-active --quiet "$service_name"; then
        log_pass "$label service is active"
    else
        log_warn "$label service is not active"
    fi
}

check_gpu_stack() {
    if command_exists nvidia-smi; then
        local gpu_count
        gpu_count="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$gpu_count" -ge "$EXPECTED_GPUS" ]; then
            log_pass "NVIDIA driver stack is available ($gpu_count GPUs visible)"
        else
            log_fail "Expected at least $EXPECTED_GPUS GPUs but only found $gpu_count"
        fi
    else
        log_fail "nvidia-smi is missing"
    fi
}

check_disk() {
    local target="/"
    local available_gb
    available_gb="$(df -BG "$target" | awk 'NR==2 {print $4}' | tr -d 'G')"
    if [ -n "$available_gb" ] && [ "$available_gb" -ge "$MIN_DISK_GB" ]; then
        log_pass "Disk space on $target is sufficient (${available_gb}GB available)"
    else
        log_warn "Disk space on $target is below the recommended ${MIN_DISK_GB}GB"
    fi
}

check_runtime() {
    echo "== Software checks =="
    check_command curl "curl"
    check_command jq "jq"
    check_command git "git"
    check_command docker "Docker Engine"
    if command_exists docker && docker compose version >/dev/null 2>&1; then
        log_pass "Docker Compose plugin is installed"
    else
        log_fail "Docker Compose plugin is missing"
    fi
    check_command nvidia-ctk "NVIDIA Container Toolkit"
    check_command openssl "OpenSSL"
    if [ "$INSTALL_OPTIONAL" = "1" ]; then
        check_command python3 "Python 3"
    fi
    echo ""

    echo "== Host checks =="
    check_gpu_stack
    check_disk
    if command_exists docker; then
        if docker info >/tmp/mistral-docker-info.txt 2>/dev/null; then
            if grep -qi 'nvidia' /tmp/mistral-docker-info.txt; then
                log_pass "Docker sees the NVIDIA runtime"
            else
                log_warn "Docker is installed but NVIDIA runtime is not visible in docker info"
            fi
        else
            log_warn "Docker is installed but current user cannot run docker info"
        fi
        rm -f /tmp/mistral-docker-info.txt
    fi
    check_service_active docker "Docker"

    if [ -f nginx/certs/server.crt ] && [ -f nginx/certs/server.key ]; then
        log_pass "TLS certificate and key files are present in nginx/certs/"
    else
        log_warn "TLS certificate and key are not both present in nginx/certs/"
    fi

    if [ -f .env ]; then
        log_pass ".env is present"
    else
        log_warn ".env is not present yet"
    fi
    echo ""
}

install_base_packages() {
    run_as_root apt-get update
    run_as_root apt-get install -y ca-certificates curl gnupg lsb-release jq git openssl
}

install_docker() {
    if command_exists docker; then
        return 0
    fi

    install_base_packages
    run_as_root install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | run_as_root gpg --dearmor -o /etc/apt/keyrings/docker.asc
        run_as_root chmod a+r /etc/apt/keyrings/docker.asc
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        ${VERSION_CODENAME} stable" | run_as_root tee /etc/apt/sources.list.d/docker.list >/dev/null

    run_as_root apt-get update
    run_as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! is_root; then
        run_as_root usermod -aG docker "$USER" || true
    fi
}

install_nvidia_container_toolkit() {
    if command_exists nvidia-ctk; then
        return 0
    fi

    install_base_packages
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        run_as_root gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
        run_as_root tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    run_as_root apt-get update
    run_as_root apt-get install -y nvidia-container-toolkit

    if command_exists nvidia-ctk; then
        run_as_root nvidia-ctk runtime configure --runtime=docker
        if command_exists systemctl; then
            run_as_root systemctl restart docker
        fi
    fi
}

install_optional_packages() {
    run_as_root apt-get install -y python3 python3-venv python3-pip
}

install_missing() {
    require_supported_os
    echo "Installing required host software for the Mistral 7B stack..."
    install_base_packages
    install_docker
    install_nvidia_container_toolkit
    if [ "$INSTALL_OPTIONAL" = "1" ]; then
        install_optional_packages
    fi
    echo ""
    echo "Re-running checks after install..."
    check_runtime
}

print_report_summary() {
    echo "========================"
    echo "Prerequisite Summary"
    echo "========================"
    echo "PASS: $PASS_COUNT"
    echo "WARN: $WARN_COUNT"
    echo "FAIL: $FAIL_COUNT"
}

print_report_details() {
    echo ""
    echo "Detailed report:"
    for line in "${REPORT_LINES[@]}"; do
        IFS='|' read -r level message <<< "$line"
        printf "  %-4s %s\n" "$level" "$message"
    done
}

case "$MODE" in
    check)
        check_runtime
        print_report_summary
        ;;
    report)
        check_runtime
        print_report_summary
        print_report_details
        ;;
    install)
        install_missing
        print_report_summary
        print_report_details
        ;;
    *)
        echo "Usage: $0 [check|report|install]" >&2
        exit 1
        ;;
esac
