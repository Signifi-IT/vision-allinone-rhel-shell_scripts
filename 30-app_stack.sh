#!/bin/bash

###############################################################################
# Description:
#   Configures a full application stack PHP 8.2, PostgreSQL 14, HTTPD and supporting system services on RHEL-based systems:
#     - Requires root privileges
#     - Logs all actions to /var/log/vision_deployment.log
#     - Imports the EPEL GPG key and installs EPEL repository
#     - Enables the CodeReady Builder repository
#     - Disables unnecessary PostgreSQL and EPEL repositories
#     - Cleans and rebuilds the DNF package metadata cache
#     - Resets and enables PHP 8.2 module stream and installs PHP profile
#     - Performs a full system package upgrade
#     - Installs the PHP 8.2 common profile package group
#     - Cleans and rebuilds the DNF package metadata cache
#     - Installs HTTPD, PHP, PostgreSQL 14 packages, and related application dependencies
#     - Initializes PostgreSQL database
#     - Changes PostgreSQL listener port from 5432 to 5431
#     - Configures SELinux PostgreSQL port mapping for PostgreSQL on TCP 5431
#     - Unmasks HTTPD, reloads systemd, and enables PostgreSQL 14 service
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

run "Installing EPEL repository" dnf install -y "${EPEL_RPM} --refresh"

###############################################################################
# CodeReady Builder
###############################################################################

run "Enabling CodeReady Builder repository" \
    subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms

###############################################################################
# Disable unnecessary repositories
###############################################################################

run "Disabling unnecessary DNF repositories" \
    dnf config-manager --set-disabled \
        epel-cisco-openh264 \
        pgdg15 \
        pgdg16 \
        pgdg17 \
        pgdg18

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

run "Installing PHP 8.2 common profile" dnf install -y "@php:8.2/common --refresh"

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

run "Installing application packages" dnf install -y "${REQUIRED_PACKAGES[@]} --refresh"

###############################################################################
# PostgreSQL initialization
###############################################################################

if [[ ! -d "${POSTGRES_DATA_DIR}" ]] || [[ ! -f "${POSTGRES_VERSION_FILE}" ]]; then
    run "Initializing PostgreSQL database" /usr/pgsql-14/bin/postgresql-14-setup initdb
else
    log "PostgreSQL already initialized"
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

for svc in auditd httpd php-fpm postgresql-14 restorecond; do
    run "Enabling and starting ${svc}" systemctl enable --now "${svc}"
done

###############################################################################
# SELinux booleans
###############################################################################

SEBOOLS=(
    httpd_can_network_connect_db
    haproxy_connect_any
)

for bool in "${SEBOOLS[@]}"; do
    run "Enabling SELinux boolean (runtime) ${bool}" setsebool "${bool}" on

    run "Enabling SELinux boolean (persistent) ${bool}" setsebool -P "${bool}" on
done

###############################################################################
# Completion
###############################################################################

log "Application stack configuration completed successfully."
