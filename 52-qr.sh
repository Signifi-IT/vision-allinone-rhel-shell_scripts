#!/bin/bash

###############################################################################
# Description:
#   Deploys the QR repository to an existing Vision portal:
#     - Requires root privileges
#     - Logs operations to /var/log/vision_deployment.log
#     - Loads configuration using --answer-file
#     - Uses the same Bitbucket SSH key mechanism as 50.sh
#     - Clones the requested QR branch to a temporary directory under /var/www
#     - Copies repository content to /var/www/${PORTAL_URL}/qr/
#     - Sets target directory permissions to 0755 and ownership to root:apache
#     - Removes the temporary clone after successful deployment
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
  bash $(basename "$0") --answer-file /tmp/scripts/answers-qr.txt
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
# Validate required variables and SSH key
###############################################################################

REQUIRED_VARS=(
    QR_URL
    QR_BRANCH
    PORTAL_URL
    BITBUCKET_KEY
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined or is empty"
        exit 1
    fi
done

###############################################################################
# Validate required files
###############################################################################

REQUIRED_FILES=(
    "${BITBUCKET_KEY}"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        error "Required file not found: ${file}"
        exit 1
    fi
done

###############################################################################
# Constants
###############################################################################

QR_DIR="/var/www/qr_api"
APP_DIR="/var/www/${PORTAL_URL}"
QR_API_DIR="${APP_DIR}/qr"

###############################################################################
# Git SSH configuration
###############################################################################

run "Setting Bitbucket SSH key permissions" chmod 0400 "${BITBUCKET_KEY}"
run "Setting Bitbucket SSH key ownership" chown root:root "${BITBUCKET_KEY}"

export GIT_SSH_COMMAND="ssh -i ${BITBUCKET_KEY} -o StrictHostKeyChecking=accept-new"

###############################################################################
# Clone QR API repository to a temporary directory under /var/www
###############################################################################

clone_repo() {

    local repo="$1"
    local branch="$2"
    local dest="$3"

    run "Cloning repository into: ${dest}" \
        git clone \
            --quiet \
            --branch "${branch}" \
            "${repo}" \
            "${dest}"
}

clone_repo \
    "${QR_URL}" \
    "${QR_BRANCH}" \
    "${QR_DIR}"

###############################################################################
# Deploy QR API content
###############################################################################

run "Copying QR API repository content to ${QR_API_DIR}" \
    cp -a "${QR_DIR}/." "${QR_API_DIR}/"

run "Setting QR API directory permissions" chmod 0755 "${QR_API_DIR}"
run "Setting QR API ownership recursively" chown -R root:apache "${QR_API_DIR}"

###############################################################################
# Remove temporary clone
###############################################################################

run "Removing temporary QR API clone" rm -rf "${QR_DIR}"

###############################################################################
# Completion
###############################################################################

unset GIT_SSH_COMMAND
log "QR API deployment completed successfully: ${QR_API_DIR}"
