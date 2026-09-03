#!/bin/bash

###############################################################################
# Description:
#   Configures SELinux contexts and filesystem permissions for application
#   directories on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Requires --answer-file argument to load the desired answer file
#     - Supports running against different portal answer files
#     - Loads configuration from the provided answer file
#     - Validates required variables
#     - Validates required application directories
#     - Sets application directory permissions recursively to 0755
#     - Sets application file permissions recursively to 0644
#     - Sets recursive application ownership to root:apache
#     - Configures SELinux file context rules for the application sessions directory
#     - Configures SELinux file context rules for the application media directory
#     - Adds or updates SELinux file context rules as needed
#     - Applies SELinux contexts recursively using restorecon
#     - Sets writable permissions on the primary application media directory
#     - Sets writable permissions on the primary application sessions directory
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
# Usage
###############################################################################

usage() {
    cat <<EOF
Usage:
  bash $(basename "$0") --answer-file <filepath>.txt

Example:
  bash $(basename "$0") --answer-file /tmp/scripts/answers.txt
  bash $(basename "$0") --answer-file /tmp/scripts/answers-add_portal.txt
EOF
}

###############################################################################
# Parse arguments
###############################################################################

ANSWER_FILE=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --answer-file)
            if [[ -z "${2:-}" ]]; then
                error "Missing value for --answer-file"
                usage
                exit 1
            fi

            ANSWER_FILE="$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${ANSWER_FILE}" ]]; then
    error "Required argument --answer-file is missing"
    usage
    exit 1
fi

###############################################################################
# Load configuration
###############################################################################

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="${ANSWER_FILE}"

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

run "Setting application directory permissions" \
    find "${APP_DIR}" -type d -exec chmod 0755 {} +

run "Setting application file permissions" \
    find "${APP_DIR}" -type f -exec chmod 0644 {} +

run "Setting application ownership" chown -R root:apache "${APP_DIR}"

###############################################################################
# Configure SELinux file contexts
###############################################################################

run "Configuring SELinux context for sessions directory" \
    bash -c "semanage fcontext -a -t httpd_sys_rw_content_t '${SESSIONS_DIR}(/.*)?' 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t '${SESSIONS_DIR}(/.*)?'"

run "Configuring SELinux context for media directory" \
    bash -c "semanage fcontext -a -t httpd_sys_rw_content_t '${MEDIA_DIR}(/.*)?' 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t '${MEDIA_DIR}(/.*)?'"

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
