#!/bin/bash

###############################################################################
# Description:
#   Rotates an existing portal HAProxy TLS certificate on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads PORTAL_URL and NEW_CERT_PATH from --answer-file
#     - Validates the replacement PEM certificate and private key
#     - Replaces /etc/haproxy/certs/<PORTAL_URL>.pem
#     - Preserves root:root ownership and 0600 permissions
#     - Validates HAProxy configuration before restarting the service
#     - Restores the prior certificate if validation or restart fails
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
    PORTAL_URL
    NEW_CERT_PATH
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined or is empty"
        exit 1
    fi
done

###############################################################################
# Validate PORTAL_URL as a valid DNS hostname.
###############################################################################

if [[ ! "${PORTAL_URL}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
   [[ "${PORTAL_URL}" == *..* ]]; then
    error "Invalid PORTAL_URL (expected a DNS hostname): ${PORTAL_URL}"
    exit 1
fi

###############################################################################
# Constants
###############################################################################

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_CERT_DIR="/etc/haproxy/certs"
CERT_DEST="${HAPROXY_CERT_DIR}/${PORTAL_URL}.pem"

###############################################################################
# Validate required files
###############################################################################

REQUIRED_FILES=(
    "${NEW_CERT_PATH}"
    "${CERT_DEST}"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        error "Required file not found: ${file}"
        exit 1
    fi
done

###############################################################################
# Deploy certificate; roll back if configuration/restart fails
###############################################################################

if cmp -s "${NEW_CERT_PATH}" "${CERT_DEST}"; then
    log "Certificate content is unchanged; no rotation is required"
    log "SSL rotation completed successfully."
    exit 0
fi

STAGED_CERT="$(mktemp "${HAPROXY_CERT_DIR}/.${PORTAL_URL}.new.XXXXXX")"
BACKUP_CERT="$(mktemp "${HAPROXY_CERT_DIR}/.${PORTAL_URL}.backup.XXXXXX")"
CERT_REPLACED=0
ROTATION_COMPLETED=0

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ "${CERT_REPLACED}" -eq 1 && "${ROTATION_COMPLETED}" -eq 0 ]]; then
        warn "Restoring previous HAProxy certificate: ${CERT_DEST}"
        if cp -p "${BACKUP_CERT}" "${CERT_DEST}"; then
            if command -v restorecon >/dev/null 2>&1; then
                restorecon "${CERT_DEST}" || true
            fi
            if ! systemctl restart haproxy; then
                error "HAProxy could not be restarted with the restored certificate; manual intervention required"
            fi
        else
            error "Certificate rollback failed; backup remains at: ${BACKUP_CERT}"
            rm -f "${STAGED_CERT}"
            exit 1
        fi
    fi
    rm -f "${STAGED_CERT}" "${BACKUP_CERT}"
    exit "${rc}"
}
trap cleanup EXIT

run "Backing up existing HAProxy certificate" cp -p "${CERT_DEST}" "${BACKUP_CERT}"
run "Staging replacement HAProxy certificate" cp -f "${NEW_CERT_PATH}" "${STAGED_CERT}"
run "Setting new certificate ownership" chown root:root "${STAGED_CERT}"
run "Setting new certificate permissions" chmod 0600 "${STAGED_CERT}"

# Atomic rename avoids presenting a partially written PEM to HAProxy.
run "Replacing HAProxy certificate: ${CERT_DEST}" mv -f "${STAGED_CERT}" "${CERT_DEST}"
CERT_REPLACED=1

if command -v restorecon >/dev/null 2>&1; then
    run "Restoring HAProxy certificate SELinux context" restorecon "${CERT_DEST}"
fi

run "Validating HAProxy configuration" haproxy -c -f "${HAPROXY_CFG}" -f "${HAPROXY_CONF_DIR}"
run "Restarting HAProxy service" systemctl restart haproxy

ROTATION_COMPLETED=1
log "SSL certificate rotation completed successfully for ${PORTAL_URL}."
