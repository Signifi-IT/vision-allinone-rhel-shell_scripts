#!/bin/bash

###############################################################################
# Description:
#   Deploys the Vision application from Git repositories:
#     - Loads configuration from answers.txt
#     - Validates required files and configuration
#     - Creates application directory structure
#     - Clones or updates application repositories
#     - Deploys media, API and mobile assets
#     - Creates application session directory
#     - Removes temporary repository directories
#     - Deploys PHP configuration files
#     - Validates PHP configuration
#     - Restarts and enables PHP-FPM
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

PHP_INI_SOURCE="${SCRIPT_DIR}/files/php_files/php.ini"
PHP_WWW_CONF_SOURCE="${SCRIPT_DIR}/files/php_files/www.conf"

PHP_INI_DEST="/etc/php.ini"
PHP_WWW_CONF_DEST="/etc/php-fpm.d/www.conf"

APP_DIR="/var/www/${PORTAL_URL}"

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
        error "Required variable '${var}' is not defined"
        exit 1
    fi
done

###############################################################################
# Validate required files
###############################################################################

REQUIRED_FILES=(
    "${BITBUCKET_KEY}"
    "${PHP_INI_SOURCE}"
    "${PHP_WWW_CONF_SOURCE}"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        error "Required file not found: ${file}"
        exit 1
    fi
done

###############################################################################
# Validate required commands
###############################################################################

for cmd in git php-fpm systemctl; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        error "Required command not found: ${cmd}"
        exit 1
    fi
done

###############################################################################
# Backup helper
###############################################################################

backup_file_if_needed() {
    local file="$1"
    local backup="${file}.bak"

    if [[ -f "${file}" && ! -f "${backup}" ]]; then
        log "Creating backup: ${backup}"
        cp -p "${file}" "${backup}"
    fi
}

###############################################################################
# Application directory
###############################################################################

log "Creating application portal directory"

mkdir -p "${APP_DIR}"
chmod 0755 "${APP_DIR}"
chown root:root "${APP_DIR}"

###############################################################################
# Git SSH configuration
###############################################################################

log "Configuring Bitbucket SSH key permissions"

chmod 0400 "${BITBUCKET_KEY}"

export GIT_SSH_COMMAND="ssh -i ${BITBUCKET_KEY} -o StrictHostKeyChecking=accept-new"

###############################################################################
# Repository deployment
###############################################################################

clone_or_update_repo() {

    local repo="$1"
    local branch="$2"
    local dest="$3"

    if [[ -d "${dest}/.git" ]]; then

        run "Updating repository metadata" \
            git -C "${dest}" fetch --all --prune --quiet

        run "Checking out ${branch}" \
            git -C "${dest}" checkout -q "${branch}"

        run "Synchronizing repository" \
            git -C "${dest}" reset --hard "origin/${branch}"

    else

        run "Cloning repository into: ${dest}" \
            git clone \
                --quiet \
                --branch "${branch}" \
                "${repo}" \
                "${dest}"

    fi
}

clone_or_update_repo \
    "${APP_URL}" \
    "${APP_BRANCH}" \
    "/var/www/${PORTAL_URL}"

clone_or_update_repo \
    "${APP_MEDIA_URL}" \
    "${APP_MEDIA_BRANCH}" \
    "/var/www/${PORTAL_URL}_media"

clone_or_update_repo \
    "${APP_API_URL}" \
    "${APP_API_BRANCH}" \
    "/var/www/${PORTAL_URL}_api"

clone_or_update_repo \
    "${APP_MOBILE_URL}" \
    "${APP_MOBILE_BRANCH}" \
    "/var/www/${PORTAL_URL}_mobile"

###############################################################################
# Deploy media, API and mobile content
###############################################################################

for component in media api mobile; do

    SOURCE="/var/www/${PORTAL_URL}_${component}"
    DEST="/var/www/${PORTAL_URL}/${component}"

    log "Deploying ${component} content"

    mkdir -p "${DEST}"

    cp -a "${SOURCE}/." "${DEST}/"

    chmod 0755 "${DEST}"
    chown root:root "${DEST}"

done

###############################################################################
# Application sessions directory
###############################################################################

SESSION_DIR="/var/www/${PORTAL_URL}/api/application/sessions"

log "Creating application session directory"

mkdir -p "${SESSION_DIR}"
chmod 0755 "${SESSION_DIR}"
chown root:root "${SESSION_DIR}"

###############################################################################
# Remove temporary repository directories
###############################################################################

for component in media api mobile; do

    TEMP_DIR="/var/www/${PORTAL_URL}_${component}"

    if [[ -d "${TEMP_DIR}" ]]; then
        log "Removing temporary directory ${TEMP_DIR}"
        rm -rf "${TEMP_DIR}"
    fi

done

###############################################################################
# Deploy PHP configuration
###############################################################################

backup_file_if_needed "${PHP_INI_DEST}"
backup_file_if_needed "${PHP_WWW_CONF_DEST}"

run "Deploying php.ini" \
    cp -f "${PHP_INI_SOURCE}" "${PHP_INI_DEST}"

run "Deploying www.conf" \
    cp -f "${PHP_WWW_CONF_SOURCE}" "${PHP_WWW_CONF_DEST}"

chmod 0644 "${PHP_INI_DEST}" "${PHP_WWW_CONF_DEST}"
chown root:root "${PHP_INI_DEST}" "${PHP_WWW_CONF_DEST}"

###############################################################################
# Validate PHP configuration
###############################################################################

run "Validating PHP-FPM configuration" \
    php-fpm -t

###############################################################################
# Restart PHP-FPM
###############################################################################

run "Enabling PHP-FPM service" \
    systemctl enable php-fpm

run "Restarting PHP-FPM service" \
    systemctl restart php-fpm

###############################################################################
# Completion
###############################################################################

log "Vision application deployment completed successfully."
