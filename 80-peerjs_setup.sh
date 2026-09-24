#!/bin/bash

###############################################################################
# Description:
#   Deploys the PeerJS real-time communication service and integrates it with
#   HAProxy on RHEL-based systems using a native systemd service:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt
#     - Validates required user-provided variables and files
#     - Detects whether the PeerJS application directory already exists before cloning
#     - Cleans and rebuilds the DNF package metadata cache
#     - Resets the Node.js module stream
#     - Enables the Node.js 24 module stream
#     - Installs Node.js only when missing
#     - Configures Bitbucket SSH key permissions and ownership for secure Git access
#     - Clones the PeerJS repository only when the PeerJS directory does not already exist
#     - Installs PeerJS Node.js dependencies only during initial deployment
#     - Sets PeerJS application ownership and permissions
#     - Restores executable permissions for the PeerJS CLI entrypoint
#     - Creates or updates a native systemd service for PeerJS
#     - Enables and restarts the PeerJS systemd service
#     - Validates that PeerJS is listening on TCP/9000
#     - Uses the HAProxy directories and hosts.map created by the HAProxy setup script
#     - Installs Jinja2 to render HAProxy backend configuration
#     - Renders the PeerJS HAProxy backend configuration from a Jinja2 template
#     - Deploys the rendered PeerJS HAProxy backend configuration only when missing or changed
#     - Removes Jinja2 after rendering HAProxy backend configuration
#     - Installs the PeerJS TLS certificate only when missing or changed
#     - Escapes the PeerJS portal URL for safe regex-based file updates
#     - Updates HAProxy hosts.map with the PeerJS backend routing entry
#     - Validates the HAProxy configuration
#     - Enables and restarts the HAProxy service
#     - Adds or updates the PeerJS portal entry in /etc/hosts
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
# Cleanup
###############################################################################

TEMP_PEERJS_SERVICE_FILE=""
TEMP_PEERJS_HAPROXY_CFG=""

cleanup() {
    if [[ -n "${TEMP_PEERJS_SERVICE_FILE:-}" && -f "${TEMP_PEERJS_SERVICE_FILE}" ]]; then
        rm -f "${TEMP_PEERJS_SERVICE_FILE}"
    fi

    if [[ -n "${TEMP_PEERJS_HAPROXY_CFG:-}" && -f "${TEMP_PEERJS_HAPROXY_CFG}" ]]; then
        rm -f "${TEMP_PEERJS_HAPROXY_CFG}"
    fi
}

trap cleanup EXIT
trap 'error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

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

PEERJS_REPO="git@bitbucket.org:teamsignifi/peerjs-server.git"
PEERJS_BRANCH="master"

PEERJS_DIR="/var/www/${PEERJS_PORTAL_URL}"
PEERJS_SERVICE_NAME="peerjs"
PEERJS_SERVICE_FILE="/etc/systemd/system/${PEERJS_SERVICE_NAME}.service"

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_MAP_DIR="/etc/haproxy/maps"

HAPROXY_MAP_FILE="${HAPROXY_MAP_DIR}/hosts.map"

HAPROXY_CERT_DIR="/etc/haproxy/certs"
CERT_DEST="${HAPROXY_CERT_DIR}/${PEERJS_PORTAL_URL}.pem"

PEERJS_TEMPLATE="${SCRIPT_DIR}/templates/peerjs_backend.j2"
PEERJS_HAPROXY_CFG="/etc/haproxy/conf.d/${PEERJS_PORTAL_URL}_backend.cfg"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    BITBUCKET_KEY
    PEERJS_PORTAL_URL
    CERT_PATH
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
    "${CERT_PATH}"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        error "Required file not found: ${file}"
        exit 1
    fi
done

###############################################################################
# Detect existing PeerJS directory
###############################################################################

PEERJS_DIR_ALREADY_EXISTS=false

if [[ -d "${PEERJS_DIR}" ]]; then
    PEERJS_DIR_ALREADY_EXISTS=true
fi

###############################################################################
# Refresh DNF metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# Install Node.js 24
###############################################################################

run "Resetting Node.js module" dnf module reset nodejs -y
run "Enabling Node.js 24 module stream" dnf module enable nodejs:24 -y

if rpm -q nodejs >/dev/null 2>&1; then

    log "Package already installed: nodejs"

else

    run "Installing Node.js" dnf install -y --refresh nodejs

fi

###############################################################################
# Configure Git SSH
###############################################################################

run "Setting Bitbucket SSH key permissions" chmod 0400 "${BITBUCKET_KEY}"
run "Setting Bitbucket SSH key ownership" chown root:root "${BITBUCKET_KEY}"

export GIT_SSH_COMMAND="ssh -i ${BITBUCKET_KEY} -o StrictHostKeyChecking=accept-new"

###############################################################################
# Deploy PeerJS repository
###############################################################################

if [[ -d "${PEERJS_DIR}" ]]; then

    log "PeerJS directory already exists, skipping repository deployment: ${PEERJS_DIR}"

else

    clone_repo() {

        local repo="$1"
        local branch="$2"
        local dest="$3"

        run "Cloning repository into ${dest}" \
            git clone \
                --quiet \
                --branch "${branch}" \
                "${repo}" \
                "${dest}"
    }

    clone_repo \
        "${PEERJS_REPO}" \
        "${PEERJS_BRANCH}" \
        "${PEERJS_DIR}"

fi

###############################################################################
# Install dependencies
###############################################################################

if [[ "${PEERJS_DIR_ALREADY_EXISTS}" == "true" ]]; then

    log "PeerJS directory already existed, skipping dependency installation: ${PEERJS_DIR}"

else

    run "Installing PeerJS dependencies" bash -c "cd '${PEERJS_DIR}' && /usr/bin/npm ci"

fi

###############################################################################
# Application permissions
###############################################################################

run "Setting PeerJS application ownership" chown -R root:apache "${PEERJS_DIR}"

run "Setting PeerJS application directory permissions" \
    find "${PEERJS_DIR}" -type d -exec chmod 0755 {} +

run "Setting PeerJS application file permissions" \
    find "${PEERJS_DIR}" -type f -exec chmod 0644 {} +

if [[ -f "${PEERJS_DIR}/bin/peerjs" ]]; then
    run "Setting PeerJS executable permissions" chmod 0755 "${PEERJS_DIR}/bin/peerjs"
else
    error "PeerJS executable not found: ${PEERJS_DIR}/bin/peerjs"
    exit 1
fi

###############################################################################
# Configure PeerJS systemd service
###############################################################################

log "Rendering PeerJS systemd service file"

TEMP_PEERJS_SERVICE_FILE="$(mktemp)"

cat > "${TEMP_PEERJS_SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=PeerJS Server for ${PEERJS_PORTAL_URL}
After=network.target

[Service]
Type=simple
WorkingDirectory=${PEERJS_DIR}
Environment=PORT=9000
ExecStart=/usr/bin/node ${PEERJS_DIR}/app.js
Restart=always
RestartSec=5
SyslogIdentifier=peerjs

[Install]
WantedBy=multi-user.target
EOF_SERVICE

if [[ -f "${PEERJS_SERVICE_FILE}" ]] && cmp -s "${TEMP_PEERJS_SERVICE_FILE}" "${PEERJS_SERVICE_FILE}"; then

    log "PeerJS systemd service file already up to date: ${PEERJS_SERVICE_FILE}"

else

    log "Deploying PeerJS systemd service file: ${PEERJS_SERVICE_FILE}"
    cp -f "${TEMP_PEERJS_SERVICE_FILE}" "${PEERJS_SERVICE_FILE}"
    run "Setting PeerJS systemd service file permissions" chmod 0644 "${PEERJS_SERVICE_FILE}"
    run "Setting PeerJS systemd service file ownership" chown root:root "${PEERJS_SERVICE_FILE}"

fi

run "Reloading systemd daemon" systemctl daemon-reload
run "Enabling PeerJS systemd service" systemctl enable "${PEERJS_SERVICE_NAME}.service"
run "Restarting PeerJS systemd service" systemctl restart "${PEERJS_SERVICE_NAME}.service"

###############################################################################
# Validate PeerJS listener
###############################################################################

log "Validating PeerJS listener on TCP/9000"

sleep 3

PEERJS_LISTENING="$(ss -tulpn | awk '/:9000[[:space:]]/ { print "yes"; exit }')"

if [[ "${PEERJS_LISTENING}" == "yes" ]]; then
    log "PeerJS is listening on TCP/9000"
else
    journalctl -u "${PEERJS_SERVICE_NAME}.service" --no-pager -n 50 || true
    error "PeerJS is not listening on TCP/9000"
    exit 1
fi

###############################################################################
# Install Jinja2
###############################################################################

run "Installing python3-jinja2" dnf install -y --refresh python3-jinja2

###############################################################################
# Render PeerJS backend configuration
###############################################################################

log "Rendering PeerJS backend configuration"

TEMP_PEERJS_HAPROXY_CFG="$(mktemp)"

python3 <<EOF_PYTHON
from jinja2 import Template

with open("${PEERJS_TEMPLATE}") as f:
    template = Template(f.read())

rendered = template.render(
    peerjs_portal_url="${PEERJS_PORTAL_URL}"
)

rendered = rendered.rstrip("\n") + "\n"

with open("${TEMP_PEERJS_HAPROXY_CFG}", "w") as f:
    f.write(rendered)
EOF_PYTHON

if [[ -f "${PEERJS_HAPROXY_CFG}" ]] && cmp -s "${TEMP_PEERJS_HAPROXY_CFG}" "${PEERJS_HAPROXY_CFG}"; then

    log "PeerJS HAProxy backend configuration already up to date: ${PEERJS_HAPROXY_CFG}"

else

    log "Deploying PeerJS HAProxy backend configuration: ${PEERJS_HAPROXY_CFG}"
    cp -f "${TEMP_PEERJS_HAPROXY_CFG}" "${PEERJS_HAPROXY_CFG}"

fi

run "Setting PeerJS HAProxy backend configuration permissions" chmod 0644 "${PEERJS_HAPROXY_CFG}"
run "Setting PeerJS HAProxy backend configuration ownership" chown root:root "${PEERJS_HAPROXY_CFG}"

###############################################################################
# Remove Jinja2
###############################################################################

run "Removing python3-jinja2" dnf remove -y python3-jinja2

###############################################################################
# Install certificate
###############################################################################

if [[ -f "${CERT_DEST}" ]] && cmp -s "${CERT_PATH}" "${CERT_DEST}"; then

    log "PeerJS TLS certificate already up to date: ${CERT_DEST}"

else

    run "Installing PeerJS TLS certificate" cp -f "${CERT_PATH}" "${CERT_DEST}"

fi

run "Setting PeerJS TLS certificate permissions" chmod 0600 "${CERT_DEST}"
run "Setting PeerJS TLS certificate ownership" chown root:root "${CERT_DEST}"

###############################################################################
# Escape PeerJS portal URL for regex operations
###############################################################################

PEERJS_PORTAL_URL_REGEX="$(printf '%s\n' "${PEERJS_PORTAL_URL}" | sed 's/[][\/.^$*+?{}|()]/\\&/g')"

###############################################################################
# Update hosts.map entry
###############################################################################

BACKEND_NAME="${PEERJS_PORTAL_URL//[-.]/_}_backend"

log "Ensuring ${PEERJS_PORTAL_URL} is mapped to ${BACKEND_NAME} in HAProxy backend map"

if grep -qE "^${PEERJS_PORTAL_URL_REGEX}[[:space:]]+${BACKEND_NAME}$" "${HAPROXY_MAP_FILE}"; then

    log "HAProxy backend map entry already exists: ${PEERJS_PORTAL_URL} ${BACKEND_NAME}"

else

    sed -i "\|^${PEERJS_PORTAL_URL_REGEX}[[:space:]]|d" "${HAPROXY_MAP_FILE}"
    echo "${PEERJS_PORTAL_URL} ${BACKEND_NAME}" >> "${HAPROXY_MAP_FILE}"

fi

###############################################################################
# Validate HAProxy
###############################################################################

run "Validating HAProxy configuration" haproxy -c -f "${HAPROXY_CFG}" -f "${HAPROXY_CONF_DIR}"

###############################################################################
# Restart HAProxy
###############################################################################

run "Enabling HAProxy" systemctl enable haproxy
run "Restarting HAProxy" systemctl restart haproxy

###############################################################################
# Update /etc/hosts entry
###############################################################################

SYSTEM_IP="$(hostname -I | awk '{print $1}')"

log "Ensuring PeerJS Portal host entry exists in /etc/hosts"

if grep -qE "^[[:space:]]*${SYSTEM_IP}[[:space:]]+${PEERJS_PORTAL_URL_REGEX}$" /etc/hosts; then

    log "/etc/hosts entry already exists: ${SYSTEM_IP} ${PEERJS_PORTAL_URL}"

else

    sed -i "\|[[:space:]]${PEERJS_PORTAL_URL_REGEX}$|d" /etc/hosts
    echo "${SYSTEM_IP} ${PEERJS_PORTAL_URL}" >> /etc/hosts

fi

###############################################################################
# Completion
###############################################################################

unset GIT_SSH_COMMAND
unset SYSTEM_IP
unset PEERJS_PORTAL_URL_REGEX
unset TEMP_PEERJS_SERVICE_FILE
unset TEMP_PEERJS_HAPROXY_CFG

log "PeerJS systemd deployment completed successfully."
