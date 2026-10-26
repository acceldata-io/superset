#!/usr/bin/env bash
# Install prerequisites for building Apache Superset from source.
# Idempotent — safe to run multiple times.
# Supported: RHEL 8/9/10 (and clones), Ubuntu 20.04/22.04
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
# RHEL 8 keeps the rpm database in Berkeley DB. /var/lib/rpm/__db.* are only
# the BDB environment (locks/shared-memory cache); the package data lives in
# Packages, Name, Basenames, ... The build images ship __db.* files that the
# container cannot open for writing, so the first yum transaction fails with:
#   db5 error(-30969) from dbenv->open: BDB0091 DB_VERSION_MISMATCH
#   cannot open Packages database in /var/lib/rpm
# A yum transaction that updates glibc leaves them stale again. rpm recreates
# the environment on the next open, so removing them before each write is safe.
# RHEL 9+ uses sqlite and has no __db.* files, so this is a no-op there.
reset_rpmdb_env() {
    if compgen -G "/var/lib/rpm/__db.*" > /dev/null; then
        log "Clearing stale rpm Berkeley DB environment (/var/lib/rpm/__db.*)"
        rm -f /var/lib/rpm/__db.*
    fi
}

yum_cmd() {
    reset_rpmdb_env
    yum "$@"
}

yum_install() {
    local pkg
    for pkg in "$@"; do
        if ! rpm -q "${pkg}" &>/dev/null; then
            log "Installing ${pkg} ..."
            yum_cmd install -y "${pkg}"
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
    yum_cmd install -y epel-release || true
    yum_cmd groupinstall -y "Development Tools" || yum_cmd install -y gcc gcc-c++ make
    yum_install \
        git curl wget tar gzip bzip2 zlib-devel bzip2-devel \
        openssl-devel libffi-devel readline-devel sqlite-devel \
        xz-devel tk-devel \
        cyrus-sasl-devel cyrus-sasl-gssapi \
        krb5-devel \
        openldap-devel \
        libpq-devel \
        mysql-devel \
        pkg-config \
        jq
    # On el10, postgresql-devel resolves to postgresql-private-devel, which
    # conflicts with libpq-devel (the latter already provides libpq-fe.h and
    # pg_config), so only install it on older releases.
    if [ "${OS_MAJOR}" -lt 10 ]; then
        yum_install postgresql-devel
    fi
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
        libkrb5-dev \
        libpq-dev libecpg-dev \
        libldap2-dev \
        libmysqlclient-dev \
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
        log "Node.js $(node --version) at $(command -v node) is too old, upgrading ..."
    fi

    # Distro (AppStream) Node.js RPMs conflict with the NodeSource nodejs RPM.
    # nodejs-full-i18n pins the distro nodejs version, so remove every nodejs* RPM.
    local old_pkgs
    old_pkgs="$(rpm -qa 'nodejs*' 'npm' | grep -v nodesource || true)"
    if [ -n "${old_pkgs}" ]; then
        log "Removing distro Node.js packages: $(echo ${old_pkgs})"
        # shellcheck disable=SC2086
        yum_cmd remove -y ${old_pkgs}
    fi

    # The AppStream nodejs module filters out / conflicts with NodeSource RPMs
    yum_cmd module reset -y nodejs || warn "yum module reset nodejs failed"
    yum_cmd module disable -y nodejs || warn "yum module disable nodejs failed"

    log "Installing Node.js ${NODE_MAJOR}.x (RHEL/CentOS) ..."
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    yum_cmd install -y --allowerasing nodejs

    local rpm_major
    rpm_major="$(/usr/bin/node --version | sed 's/v//' | cut -d. -f1)"
    if [ "${rpm_major}" -lt "${NODE_MAJOR}" ]; then
        die "/usr/bin/node is $(/usr/bin/node --version) after install; expected ${NODE_MAJOR}.x"
    fi
    if [ "$(command -v node)" != "/usr/bin/node" ]; then
        warn "$(command -v node) ($(node --version)) shadows /usr/bin/node ($(/usr/bin/node --version)) on PATH"
    fi
    log "Node.js installed: $(/usr/bin/node --version)"
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
