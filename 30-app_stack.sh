#!/bin/bash

###############################################################################
# Description:
#   Configures a full application stack PHP 8.2, PostgreSQL 14, HTTPD and supporting system services on RHEL-based systems:
#     - Requires root privileges
#     - Logs all actions to /var/log/vision_deployment.log
#     - Imports the EPEL GPG key and installs the EPEL repository when missing
#     - Enables the CodeReady Builder repository
#     - Disables unnecessary PostgreSQL and EPEL repositories
#     - Cleans and rebuilds the DNF package metadata cache
#     - Resets and enables PHP 8.2 module stream
#     - Performs a full system package upgrade
#     - Installs the PHP 8.2 common profile package group when missing
#     - Cleans and rebuilds the DNF package metadata cache
#     - Installs missing HTTPD, PHP, PostgreSQL 14 packages, and related application dependencies
#     - Initializes PostgreSQL database
#     - Changes PostgreSQL listener port from 5432 to 5431
#     - Configures SELinux PostgreSQL port mapping for PostgreSQL on TCP 5431
#     - Unmasks HTTPD, reloads systemd, starts and enables PostgreSQL 14 service
#     - Enables and starts application services: HTTPD, PHP-FPM, auditd, and restorecond
#     - Enables required SELinux booleans for Apache database connectivity and HAProxy network access
###############################################################################

set -Eeuo pipefail
set -o errtrace

###############################################################################
# Logging
###############################################################################

LOG_FILE="/var/log/vision_deployment.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[INFO ] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

warn() {
    echo "[WARN ] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

trap 'error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

###############################################################################
# Root check
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
fi

###############################################################################
# Run helper
###############################################################################

run() {
    local message="$1"
    shift

    log "$message"

    local output rc

    if output=$("$@" 2>&1); then
        return 0
    else
        rc=$?
        echo "$output" >&2
        return "$rc"
    fi
}

###############################################################################
# Constants
###############################################################################

EPEL_GPG_KEY="https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9"
EPEL_RPM="https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"

POSTGRES_DATA_DIR="/var/lib/pgsql/14/data"
POSTGRES_CONF="${POSTGRES_DATA_DIR}/postgresql.conf"
POSTGRES_VERSION_FILE="${POSTGRES_DATA_DIR}/PG_VERSION"

POSTGRES_PORT="5431"
PG_ISREADY="/usr/pgsql-14/bin/pg_isready"

###############################################################################
# EPEL setup
###############################################################################

run "Importing EPEL GPG key" rpm --import "${EPEL_GPG_KEY}"

if rpm -q epel-release >/dev/null 2>&1; then

    log "EPEL repository RPM already installed"

else

    run "Installing EPEL repository" \
        dnf install -y --refresh "${EPEL_RPM}"

fi

###############################################################################
# Validate EPEL Repository Installation
###############################################################################

if [[ ! -f /etc/yum.repos.d/epel.repo ]]; then
    error "EPEL repository file was not created: /etc/yum.repos.d/epel.repo"
    exit 1
fi

EPEL_REPO_VERSION="$(rpm -q epel-release)"

log "EPEL repository package status: ${EPEL_REPO_VERSION}"

###############################################################################
# CodeReady Builder
###############################################################################

run "Enabling CodeReady Builder repository" \
    subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms

###############################################################################
# Disable unnecessary repositories
###############################################################################

UNNECESSARY_REPOS=(
    epel-cisco-openh264
    pgdg15
    pgdg16
    pgdg17
    pgdg18
)

for repo in "${UNNECESSARY_REPOS[@]}"; do
    if dnf repolist --all | awk '{print $1}' | grep -qx "${repo}"; then
        run "Disabling DNF repository: ${repo}" \
            dnf config-manager --set-disabled "${repo}"
    else
        log "DNF repository not present, skipping disable: ${repo}"
    fi
done

###############################################################################
# Refresh DNF Metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# PHP module configuration
###############################################################################

run "Resetting PHP module" dnf module reset php -y
run "Enabling PHP 8.2 module stream" dnf module enable php:8.2 -y

###############################################################################
# System upgrade
###############################################################################

run "Upgrading system packages" dnf upgrade -y --refresh

###############################################################################
# PHP profile
###############################################################################

PHP_PROFILE_PACKAGES=(
    php-cli
    php-common
    php-fpm
    php-mbstring
    php-xml
)

MISSING_PHP_PROFILE_PACKAGES=()

for package in "${PHP_PROFILE_PACKAGES[@]}"; do
    if rpm -q "${package}" >/dev/null 2>&1; then
        log "PHP profile package already installed: ${package}"
    else
        MISSING_PHP_PROFILE_PACKAGES+=("${package}")
    fi
done

if [[ "${#MISSING_PHP_PROFILE_PACKAGES[@]}" -gt 0 ]]; then

    run "Installing missing PHP 8.2 common profile packages" \
        dnf install -y --refresh "@php:8.2/common"

else

    log "PHP 8.2 common profile packages are already installed"

fi

###############################################################################
# Refresh DNF Metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# Required packages
###############################################################################

REQUIRED_PACKAGES=(
    httpd
    httpd-core
    httpd-tools
    php
    php-bcmath
    php-cli
    php-common
    php-fpm
    php-gd
    php-intl
    php-mbstring
    php-opcache
    php-pgsql
    php-process
    php-xml
    postgresql14
    postgresql14-contrib
    postgresql14-server
)

MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    if rpm -q "${package}" >/dev/null 2>&1; then
        log "Application package already installed: ${package}"
    else
        MISSING_PACKAGES+=("${package}")
    fi
done

if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then

    run "Installing missing application packages" \
        dnf install -y --refresh "${MISSING_PACKAGES[@]}"

else

    log "All application packages are already installed"

fi

###############################################################################
# PostgreSQL initialization
###############################################################################

if [[ ! -d "${POSTGRES_DATA_DIR}" ]] || [[ ! -f "${POSTGRES_VERSION_FILE}" ]]; then
    run "Initializing PostgreSQL database" /usr/pgsql-14/bin/postgresql-14-setup initdb
else
    log "PostgreSQL already initialized"
fi

###############################################################################
# Validate PostgreSQL configuration file
###############################################################################

if [[ ! -f "${POSTGRES_CONF}" ]]; then
    error "PostgreSQL configuration file not found: ${POSTGRES_CONF}"
    exit 1
fi

###############################################################################
# PostgreSQL port configuration
###############################################################################

POSTGRES_RESTART_NEEDED=0

if grep -qE '^[[:space:]]*#?[[:space:]]*port[[:space:]]*=[[:space:]]*5432([[:space:]]*#.*)?$' "${POSTGRES_CONF}"; then
    run "Changing PostgreSQL port from 5432 to ${POSTGRES_PORT}" \
        sed -i \
        's/^[[:space:]]*#\?[[:space:]]*port[[:space:]]*=[[:space:]]*5432/port = '"${POSTGRES_PORT}"'/g' "${POSTGRES_CONF}"

    POSTGRES_RESTART_NEEDED=1
else
    if grep -qE '^[[:space:]]*port[[:space:]]*=[[:space:]]*5431' "${POSTGRES_CONF}"; then
        log "PostgreSQL already configured for port ${POSTGRES_PORT}"
    else
        warn "Unable to determine PostgreSQL port configuration"
    fi
fi

###############################################################################
# SELinux PostgreSQL port
###############################################################################

if semanage port -l | grep -qE "^postgresql_port_t.*\b${POSTGRES_PORT}\b"; then
    log "SELinux PostgreSQL port ${POSTGRES_PORT} already configured"
else
    run "Adding SELinux PostgreSQL port ${POSTGRES_PORT}" \
        semanage port -a -t postgresql_port_t -p tcp "${POSTGRES_PORT}"
fi

if [[ "${POSTGRES_RESTART_NEEDED}" -eq 1 ]]; then

    run "Restarting PostgreSQL to apply port change" systemctl restart postgresql-14

else

    if systemctl is-active --quiet postgresql-14; then
        log "PostgreSQL service is already running"
    else
        run "Starting PostgreSQL service" systemctl start postgresql-14
    fi

fi

if systemctl is-enabled --quiet postgresql-14; then
    log "PostgreSQL service is already enabled"
else
    run "Enabling PostgreSQL service" systemctl enable postgresql-14
fi

###############################################################################
# Unmasking httpd service and reloading systemd
###############################################################################

run "Unmasking httpd service" systemctl unmask httpd

run "Reloading systemd daemon" systemctl daemon-reload

###############################################################################
# Verify PostgreSQL readiness
###############################################################################

log "Waiting for PostgreSQL to become ready on port ${POSTGRES_PORT}..."

for i in {1..30}; do
    if "${PG_ISREADY}" -h 127.0.0.1 -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
        log "PostgreSQL is accepting connections on port ${POSTGRES_PORT}"
        break
    fi

    sleep 1

    if [[ "${i}" -eq 30 ]]; then
        error "PostgreSQL failed to become ready on port ${POSTGRES_PORT}"
        exit 1
    fi
done

###############################################################################
# Remaining services
###############################################################################

SERVICES=(
    auditd
    httpd
    php-fpm
    restorecond
)

for svc in "${SERVICES[@]}"; do

    if systemctl is-enabled --quiet "${svc}"; then
        log "Service already enabled: ${svc}"
    else
        run "Enabling service: ${svc}" systemctl enable "${svc}"
    fi

    if systemctl is-active --quiet "${svc}"; then
        log "Service already running: ${svc}"
    else
        run "Starting service: ${svc}" systemctl start "${svc}"
    fi

done

###############################################################################
# SELinux booleans
###############################################################################

SEBOOLS=(
    httpd_can_network_connect_db
    haproxy_connect_any
)

for bool in "${SEBOOLS[@]}"; do

    CURRENT_RUNTIME_STATE="$(getsebool "${bool}" | awk '{print $3}')"

    if [[ "${CURRENT_RUNTIME_STATE}" == "on" ]]; then
        log "SELinux boolean runtime state already enabled: ${bool}"
    else
        run "Enabling SELinux boolean runtime state: ${bool}" setsebool "${bool}" on
    fi

    if semanage boolean -l | grep -qE "^${bool}[[:space:]]+\(on[[:space:]]*,[[:space:]]*on\)"; then
        log "SELinux boolean persistent state already enabled: ${bool}"
    else
        run "Enabling SELinux boolean persistent state: ${bool}" setsebool -P "${bool}" on
    fi

done

###############################################################################
# Completion
###############################################################################

log "Application stack configuration completed successfully."
