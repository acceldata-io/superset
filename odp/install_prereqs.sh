#!/usr/bin/env bash
# Install prerequisites for building Apache Superset from source.
# Idempotent — safe to run multiple times.
# Supported: RHEL 8/9 (and clones), Ubuntu 20.04/22.04
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NODE_MAJOR=20               # Node.js LTS required by superset-frontend
PY=python3.11
PY_VERSION=3.11

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[install_prereqs] $*"; }
warn() { echo "[install_prereqs] WARNING: $*" >&2; }
die()  { echo "[install_prereqs] ERROR: $*" >&2; exit 1; }

detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "Cannot detect OS — /etc/os-release not found"
    fi
    . /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID}"
    OS_MAJOR="${VERSION_ID%%.*}"
    log "Detected OS: ${OS_ID} ${OS_VERSION}"
}

# ---------------------------------------------------------------------------
# Package manager wrappers (idempotent)
# ---------------------------------------------------------------------------
yum_install() {
    local pkg
    for pkg in "$@"; do
        if ! rpm -q "${pkg}" &>/dev/null; then
            log "Installing ${pkg} ..."
            yum install -y "${pkg}"
        else
            log "${pkg} already installed"
        fi
    done
}

apt_install() {
    local pkg
    for pkg in "$@"; do
        if ! dpkg -s "${pkg}" &>/dev/null 2>&1; then
            log "Installing ${pkg} ..."
            apt-get install -y "${pkg}"
        else
            log "${pkg} already installed"
        fi
    done
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
install_system_packages_rhel() {
    log "Installing system packages (RHEL/CentOS/Rocky ${OS_MAJOR}) ..."
    yum install -y epel-release || true
    yum groupinstall -y "Development Tools" || yum install -y gcc gcc-c++ make
    yum_install \
        git curl wget tar gzip bzip2 zlib-devel bzip2-devel \
        openssl-devel libffi-devel readline-devel sqlite-devel \
        xz-devel tk-devel \
        cyrus-sasl-devel cyrus-sasl-gssapi \
        postgresql-devel \
        openldap-devel \
        libpq-devel \
        pkg-config \
        jq
}

install_system_packages_ubuntu() {
    log "Installing system packages (Ubuntu ${OS_VERSION}) ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt_install \
        git curl wget tar gzip build-essential pkg-config \
        zlib1g-dev libbz2-dev libssl-dev libffi-dev \
        libreadline-dev libsqlite3-dev libncurses5-dev \
        libncursesw5-dev xz-utils tk-dev liblzma-dev \
        libsasl2-dev libsasl2-modules-gssapi-mit \
        libpq-dev libecpg-dev \
        libldap2-dev \
        jq
}

# ---------------------------------------------------------------------------
# Python 3.11 (yum on RHEL, deadsnakes PPA on Ubuntu)
# ---------------------------------------------------------------------------
install_python_rhel() {
    if command -v ${PY} &>/dev/null; then
        log "${PY} already available: $(${PY} --version)"
        ensure_pip_rhel
        return
    fi

    log "Installing Python ${PY_VERSION} via yum ..."
    yum_install python3.11 python3.11-pip python3.11-devel

    log "Python installed: $(${PY} --version)"
    ensure_pip_rhel
}

ensure_pip_rhel() {
    if ! ${PY} -m pip --version &>/dev/null; then
        log "Bootstrapping pip for ${PY} ..."
        ${PY} -m ensurepip --upgrade || curl -fsSL https://bootstrap.pypa.io/get-pip.py | ${PY}
    fi
    log "pip available: $(${PY} -m pip --version)"
    # Don't upgrade system-level pip/setuptools — they're owned by rpm.
    # The build script creates a venv which gets its own copies.
}

install_python_ubuntu() {
    if command -v ${PY} &>/dev/null; then
        log "${PY} already available: $(${PY} --version)"
        ensure_pip_ubuntu
        return
    fi

    log "Installing Python ${PY_VERSION} via deadsnakes PPA ..."
    apt_install software-properties-common
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update -y
    apt_install python3.11 python3.11-venv python3.11-dev python3.11-distutils

    log "Python installed: $(${PY} --version)"
    ensure_pip_ubuntu
}

ensure_pip_ubuntu() {
    if ! ${PY} -m pip --version &>/dev/null; then
        log "Bootstrapping pip for ${PY} ..."
        curl -fsSL https://bootstrap.pypa.io/get-pip.py | ${PY}
    fi
    ${PY} -m pip install --upgrade pip setuptools wheel
}

# ---------------------------------------------------------------------------
# Node.js 20.x
# ---------------------------------------------------------------------------
install_node_rhel() {
    if command -v node &>/dev/null; then
        local cur
        cur="$(node --version | sed 's/v//' | cut -d. -f1)"
        if [ "${cur}" -ge "${NODE_MAJOR}" ]; then
            log "Node.js already installed: $(node --version)"
            return
        fi
        log "Node.js $(node --version) is too old, removing before upgrade ..."
        yum remove -y nodejs npm 2>/dev/null || true
    fi

    # Disable the RHEL AppStream nodejs module to avoid conflicts
    yum module disable -y nodejs 2>/dev/null || true

    log "Installing Node.js ${NODE_MAJOR}.x (RHEL/CentOS) ..."
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    yum install -y nodejs
    log "Node.js installed: $(node --version)"
}

install_node_ubuntu() {
    if command -v node &>/dev/null; then
        local cur
        cur="$(node --version | sed 's/v//' | cut -d. -f1)"
        if [ "${cur}" -ge "${NODE_MAJOR}" ]; then
            log "Node.js already installed: $(node --version)"
            return
        fi
        log "Node.js $(node --version) is too old, upgrading ..."
    fi

    log "Installing Node.js ${NODE_MAJOR}.x (Ubuntu) ..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
    log "Node.js installed: $(node --version)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "============================================"
    log "Superset Build Prerequisites Installer"
    log "============================================"

    detect_os

    case "${OS_ID}" in
        rhel|centos|rocky|almalinux|fedora)
            install_system_packages_rhel
            install_python_rhel
            install_node_rhel
            ;;
        ubuntu|debian)
            install_system_packages_ubuntu
            install_python_ubuntu
            install_node_ubuntu
            ;;
        *)
            die "Unsupported OS: ${OS_ID} ${OS_VERSION}. Supported: RHEL 8/9, Ubuntu 20/22."
            ;;
    esac

    log ""
    log "============================================"
    log "Prerequisites installed successfully"
    log "  Python : $(${PY} --version 2>&1)"
    log "  Node   : $(node --version 2>&1)"
    log "  npm    : $(npm --version 2>&1)"
    log "============================================"
}

main "$@"
