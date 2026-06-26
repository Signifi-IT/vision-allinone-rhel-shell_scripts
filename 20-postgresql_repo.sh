#!/bin/bash

###############################################################################
# Description:
#   Configures PostgreSQL repositories on RHEL-based systems:
#     - Refreshes DNF metadata
#     - Disables built-in PostgreSQL module
#     - Imports PostgreSQL GPG signing key
#     - Installs PostgreSQL repository RPM
#     - Ensures PostgreSQL module remains disabled
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
# Root Check
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
fi

###############################################################################
# Run Helper
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

PGDG_GPG_KEY_URL="https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL"

PGDG_REPO_RPM="https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"

###############################################################################
# Refresh DNF Metadata
###############################################################################

run "Refreshing DNF package metadata" dnf makecache -y

###############################################################################
# Disable Built-in PostgreSQL Module
###############################################################################

run "Disabling built-in PostgreSQL module" dnf -qy module disable postgresql

###############################################################################
# Import PostgreSQL GPG Key
###############################################################################

run "Importing PostgreSQL repository GPG key" rpm --import "${PGDG_GPG_KEY_URL}"

###############################################################################
# Install PostgreSQL Repository
###############################################################################

run "Installing PostgreSQL repository RPM" dnf install -y "${PGDG_REPO_RPM}"

run "Refreshing DNF package metadata" dnf makecache -y

###############################################################################
# Ensure PostgreSQL Module Remains Disabled
###############################################################################

run "Ensuring PostgreSQL module remains disabled" dnf -qy module disable postgresql

###############################################################################
# Completion
###############################################################################

log "PostgreSQL repository configuration completed successfully."
