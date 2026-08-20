#!/bin/bash

###############################################################################
# Description:
#   Configures SELinux contexts and filesystem permissions for writable
#   application directories on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt
#     - Validates required variables
#     - Configures recursive application ownership and permission settings
#     - Configures SELinux file contexts for the application sessions directory
#     - Configures SELinux file contexts for the application media directory
#     - Applies SELinux contexts recursively using restorecon
#     - Sets writable permissions on the application media directory
#     - Sets writable permissions on the application sessions directory
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
# Load configuration
###############################################################################

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="${SCRIPT_DIR}/answers.txt"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    error "Configuration file not found: ${CONFIG_FILE}"
    exit 1
fi

log "Loading configuration from ${CONFIG_FILE}..."

if ! source "${CONFIG_FILE}"; then
    error "Failed to load configuration file"
    exit 1
fi

###############################################################################
# Constants
###############################################################################

APP_DIR="/var/www/${PORTAL_URL}"
MEDIA_DIR="${APP_DIR}/media"
SESSIONS_DIR="${APP_DIR}/api/application/sessions"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    PORTAL_URL
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined or is empty"
        exit 1
    fi
done

###############################################################################
# Validate required directories
###############################################################################

REQUIRED_DIRS=(
    "${APP_DIR}"
    "${MEDIA_DIR}"
    "${SESSIONS_DIR}"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        error "Required directory not found: ${dir}"
        exit 1
    fi
done

###############################################################################
# Application permissions
###############################################################################

run "Setting application permissions" \
    find "${APP_DIR}" -type d -exec chmod 0755 {} + && \
    find "${APP_DIR}" -type f -exec chmod 0644 {} +

run "Setting application ownership" chown -R root:apache "${APP_DIR}"

###############################################################################
# Configure SELinux file contexts
###############################################################################

run "Configuring SELinux context for sessions directory" \
    semanage fcontext -a -t httpd_sys_rw_content_t "${SESSIONS_DIR}(/.*)?"

run "Configuring SELinux context for media directory" \
    semanage fcontext -a -t httpd_sys_rw_content_t "${MEDIA_DIR}(/.*)?"

###############################################################################
# Apply SELinux contexts
###############################################################################

run "Restoring SELinux contexts for ${APP_DIR}" restorecon -RvF "${APP_DIR}"

###############################################################################
# Configure filesystem permissions
###############################################################################

run "Setting media directory permissions" chmod 770 "${MEDIA_DIR}"

run "Setting sessions directory permissions" chmod 770 "${SESSIONS_DIR}"

###############################################################################
# Completion
###############################################################################

log "Application writable directory permissions configured successfully."
