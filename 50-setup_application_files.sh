#!/bin/bash

###############################################################################
# Description:
#   Deploys the Vision application from Git repositories on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt
#     - Validates required variables
#     - Validates required files
#     - Creates application directory structure under /var/www when missing
#     - Configures Bitbucket SSH key for secure Git access
#     - Clones application, media, API, and mobile repositories when application directory is missing
#     - Deploys media, API, and mobile assets into application directory structure on initial deployment
#     - Creates required application session directories on initial deployment
#     - Removes temporary repository working directories after initial deployment
#     - Backs up and deploys PHP configuration files (php.ini, www.conf)
#     - Validates PHP-FPM configuration
#     - Enables and restarts PHP-FPM service
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
# Backup helper
###############################################################################

backup_file_if_needed() {
    local file="$1"
    local backup="${file}.bak"

    if [[ ! -f "${file}" ]]; then
        warn "File does not exist, backup skipped: ${file}"
        return 0
    fi

    if [[ -f "${backup}" ]]; then
        log "Backup already exists: ${backup}"
        return 0
    fi

    log "Creating backup: ${backup}"
    cp -p "${file}" "${backup}"
}

###############################################################################
# Application directory
###############################################################################

APP_DIR_ALREADY_EXISTS=0

if [[ -d "${APP_DIR}" ]]; then

    APP_DIR_ALREADY_EXISTS=1
    log "Application portal directory already exists: ${APP_DIR}"

else

    log "Creating application portal directory: ${APP_DIR}"

    mkdir -p "${APP_DIR}"
    chmod 0755 "${APP_DIR}"
    chown root:apache "${APP_DIR}"

fi

###############################################################################
# Git SSH configuration
###############################################################################

log "Configuring Bitbucket SSH key permissions"

chmod 0400 "${BITBUCKET_KEY}"
chown root:root "${BITBUCKET_KEY}"

export GIT_SSH_COMMAND="ssh -i ${BITBUCKET_KEY} -o StrictHostKeyChecking=accept-new"

###############################################################################
# Repository deployment
###############################################################################

if [[ "${APP_DIR_ALREADY_EXISTS}" -eq 1 ]]; then

    log "Application portal directory already exists. Skipping repository deployment."

else

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
        "/var/www/${PORTAL_URL}"

    clone_repo \
        "${APP_MEDIA_URL}" \
        "${APP_MEDIA_BRANCH}" \
        "/var/www/${PORTAL_URL}_media"

    clone_repo \
        "${APP_API_URL}" \
        "${APP_API_BRANCH}" \
        "/var/www/${PORTAL_URL}_api"

    clone_repo \
        "${APP_MOBILE_URL}" \
        "${APP_MOBILE_BRANCH}" \
        "/var/www/${PORTAL_URL}_mobile"

fi

###############################################################################
# Deploy media, API and mobile content
###############################################################################

if [[ "${APP_DIR_ALREADY_EXISTS}" -eq 1 ]]; then

    log "Application portal directory already exists. Skipping media, API and mobile content deployment."

else

    for component in media api mobile; do

        SOURCE="/var/www/${PORTAL_URL}_${component}"
        DEST="/var/www/${PORTAL_URL}/${component}"

        log "Deploying ${component} content"

        mkdir -p "${DEST}"

        cp -a "${SOURCE}/." "${DEST}/"

        chmod 0755 "${DEST}"
        chown -R root:apache "${DEST}"

    done

fi

###############################################################################
# Application sessions directory
###############################################################################

SESSION_DIR="/var/www/${PORTAL_URL}/api/application/sessions"

if [[ "${APP_DIR_ALREADY_EXISTS}" -eq 1 ]]; then

    log "Application portal directory already exists. Skipping application session directory creation."

else

    log "Creating application session directory: ${SESSION_DIR}"

    mkdir -p "${SESSION_DIR}"
    chmod 0755 "${SESSION_DIR}"
    chown root:apache "${SESSION_DIR}"

fi

###############################################################################
# Remove temporary repository directories
###############################################################################

if [[ "${APP_DIR_ALREADY_EXISTS}" -eq 1 ]]; then

    log "Application portal directory already exists. Skipping temporary repository cleanup."

else

    for component in media api mobile; do

        TEMP_DIR="/var/www/${PORTAL_URL}_${component}"

        if [[ -d "${TEMP_DIR}" ]]; then
            log "Removing temporary directory ${TEMP_DIR}"
            rm -rf "${TEMP_DIR}"
        fi

    done

fi

###############################################################################
# Deploy and Validate PHP configuration
###############################################################################

backup_file_if_needed "${PHP_INI_DEST}"
backup_file_if_needed "${PHP_WWW_CONF_DEST}"

run "Deploying php.ini" cp -f "${PHP_INI_SOURCE}" "${PHP_INI_DEST}"
run "Deploying www.conf" cp -f "${PHP_WWW_CONF_SOURCE}" "${PHP_WWW_CONF_DEST}"

chmod 0644 "${PHP_INI_DEST}" "${PHP_WWW_CONF_DEST}"
chown root:root "${PHP_INI_DEST}" "${PHP_WWW_CONF_DEST}"

run "Validating PHP-FPM configuration" php-fpm -t

###############################################################################
# Restart PHP-FPM
###############################################################################

run "Restarting PHP-FPM service" systemctl restart php-fpm
run "Enabling PHP-FPM service" systemctl enable php-fpm

###############################################################################
# Completion
###############################################################################

unset GIT_SSH_COMMAND
log "Vision application deployment completed successfully."
