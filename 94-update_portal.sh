#!/bin/bash

###############################################################################
# Description:
#   Update the Vision application on RHEL-based systems:
#     - This is what it is doing
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
CONFIG_FILE="${SCRIPT_DIR}/answers-update_portal.txt"

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

APP_TEMP_DIR="/tmp/${PORTAL_URL}"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    BITBUCKET_KEY
    PORTAL_URL
    APP_URL
    APP_BRANCH
    APP_MEDIA_URL
    APP_MEDIA_BRANCH
    APP_API_URL
    APP_API_BRANCH
    APP_MOBILE_URL
    APP_MOBILE_BRANCH
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
# Application directory
###############################################################################

APP_DIR_ALREADY_EXISTS=0

if [[ -d "${APP_DIR}" ]]; then

    APP_DIR_ALREADY_EXISTS=1
    log "Application portal deployed at: ${APP_DIR}"

else

    log "Application portal ${APP_DIR} is not deployed"

fi

###############################################################################
# Git SSH configuration
###############################################################################

run "Setting Bitbucket SSH key permissions" chmod 0400 "${BITBUCKET_KEY}"
run "Setting Bitbucket SSH key ownership" chown root:root "${BITBUCKET_KEY}"

export GIT_SSH_COMMAND="ssh -i ${BITBUCKET_KEY} -o StrictHostKeyChecking=accept-new"

###############################################################################
# Repository deployment
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
    "${APP_URL}" \
    "${APP_BRANCH}" \
    "${APP_TEMP_DIR}"

clone_repo \
    "${APP_MEDIA_URL}" \
    "${APP_MEDIA_BRANCH}" \
    "${APP_TEMP_DIR}_media"

clone_repo \
    "${APP_API_URL}" \
    "${APP_API_BRANCH}" \
    "${APP_TEMP_DIR}_api"

clone_repo \
    "${APP_MOBILE_URL}" \
    "${APP_MOBILE_BRANCH}" \
    "${APP_TEMP_DIR}_mobile"

###############################################################################
# Deploy media, API and mobile content
###############################################################################

for component in media api mobile; do

    SOURCE="${APP_TEMP_DIR}_${component}"
    DEST="${APP_TEMP_DIR}/${component}"

    log "Deploying ${component} content"

    mkdir -p "${DEST}"

    cp -a "${SOURCE}/." "${DEST}/"

    chmod 0755 "${DEST}"
    chown -R root:apache "${DEST}"

done