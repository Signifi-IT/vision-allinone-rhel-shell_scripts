#!/bin/bash

###############################################################################
# Description:
#   Deploys PeerJS real-time communication service and integrates it with HAProxy:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt and validates required variables and files
#     - Installs Node.js 24
#     - Installs and configures PM2 process manager
#     - Deploys PeerJS application from Bitbucket
#     - Installs Node.js dependencies using npm ci
#     - Starts PeerJS application under PM2 and persists process list
#     - Installs HAProxy TLS certificate for PeerJS endpoint
#     - Installs Jinja2 to render HAProxy backend configuration
#     - Generates HAProxy backend configuration
#     - Removes Jinja2 after rendering configurations
#     - Updates HAProxy hosts.map routing entry for PeerJS portal
#     - Validates HAProxy configuration
#     - Restarts, enables, and activates HAProxy service
#     - Adds PeerJS hostname mapping to /etc/hosts if not present
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

PEERJS_REPO="git@bitbucket.org:teamsignifi/peerjs-server.git"
PEERJS_BRANCH="master"

PEERJS_DIR="/var/www/${PEERJS_PORTAL_URL}"

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_MAP_DIR="/etc/haproxy/maps"

HAPROXY_MAP_FILE="${HAPROXY_MAP_DIR}/hosts.map"

HAPROXY_CERT_DIR="/etc/haproxy/certs"
CERT_SOURCE="${CERT_PATH}"
CERT_DEST="${HAPROXY_CERT_DIR}/${PEERJS_PORTAL_URL}.pem"

PEERJS_TEMPLATE="${SCRIPT_DIR}/templates/peerjs_backend.j2"
PEERJS_HAPROXY_CFG="/etc/haproxy/conf.d/${PEERJS_PORTAL_URL}_backend.cfg"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    BITBUCKET_KEY
    PEERJS_PORTAL_URL
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
    "${CERT_SOURCE}"
    "${PEERJS_TEMPLATE}"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        error "Required file not found: ${file}"
        exit 1
    fi
done

###############################################################################
# Install Nodejs 24
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

run "Resetting Node.js module" dnf module reset nodejs -y

run "Enabling Node.js 24 module stream" dnf module enable nodejs:24 -y

run "Installing Node.js" dnf install -y nodejs

###############################################################################
# Install PM2
###############################################################################

run "Installing PM2 globally" /usr/bin/npm install -g pm2

###############################################################################
# Configure PM2 startup
###############################################################################

run "Configuring PM2 startup" /usr/local/bin/pm2 startup systemd -u root --hp /root

###############################################################################
# Configure Git SSH
###############################################################################

log "Configuring Bitbucket SSH key permissions"

chmod 0400 "${BITBUCKET_KEY}"

export GIT_SSH_COMMAND="ssh -i ${BITBUCKET_KEY} -o StrictHostKeyChecking=accept-new"

###############################################################################
# Deploy PeerJS repository
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

        run "Cloning repository into ${dest}" \
            git clone \
                --quiet \
                --branch "${branch}" \
                "${repo}" \
                "${dest}"

    fi
}

clone_or_update_repo \
    "${PEERJS_REPO}" \
    "${PEERJS_BRANCH}" \
    "${PEERJS_DIR}"

###############################################################################
# Install dependencies
###############################################################################

run "Installing PeerJS dependencies" bash -c "cd '${PEERJS_DIR}' && /usr/bin/npm ci"

###############################################################################
# Application permissions
###############################################################################

run "Setting PeerJS application permissions" \
    find "${PEERJS_DIR}" -type d -exec chmod 0755 {} + && \
    find "${PEERJS_DIR}" -type f -exec chmod 0644 {} +

run "Setting PeerJS application ownership" chown -R root:root "${PEERJS_DIR}"

###############################################################################
# PM2 deployment
###############################################################################

if /usr/local/bin/pm2 list | grep -q 'peerjs'; then

    run "Restarting PeerJS PM2 application" \
        bash -c "cd '${PEERJS_DIR}' && /usr/local/bin/pm2 restart peerjs"

else

    run "Starting PeerJS PM2 application" \
        bash -c "cd '${PEERJS_DIR}' && /usr/local/bin/pm2 start app.js --name peerjs"

fi

run "Persisting PM2 process list" \
    bash -c "cd '${PEERJS_DIR}' && /usr/local/bin/pm2 save"

###############################################################################
# Install Jinja2
###############################################################################

run "Installing python3-jinja2" dnf install -y python3-jinja2

###############################################################################
# Render PeerJS backend configuration
###############################################################################

log "Rendering PeerJS backend configuration"

python3 <<EOF
from jinja2 import Template

with open("${PEERJS_TEMPLATE}") as f:
    template = Template(f.read())

rendered = template.render(
    peerjs_portal_url="${PEERJS_PORTAL_URL}"
)

rendered = rendered.rstrip("\n") + "\n"

with open("${PEERJS_HAPROXY_CFG}", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${PEERJS_HAPROXY_CFG}"
chown root:root "${PEERJS_HAPROXY_CFG}"

###############################################################################
# Remove Jinja2
###############################################################################

run "Removing python3-jinja2" dnf remove -y python3-jinja2

###############################################################################
# Install certificate
###############################################################################

run "Installing PeerJS TLS certificate" cp -f "${CERT_SOURCE}" "${CERT_DEST}"

chmod 0600 "${CERT_DEST}"
chown root:root "${CERT_DEST}"

###############################################################################
# Update hosts.map entry
###############################################################################

BACKEND_NAME="${PEERJS_PORTAL_URL//[-.]/_}_backend"

log "Adding ${PEERJS_PORTAL_URL} to HAProxy backend map as ${BACKEND_NAME}"

grep -q "${PEERJS_PORTAL_URL}" "${HAPROXY_MAP_FILE}" || \
    echo "${PEERJS_PORTAL_URL} ${BACKEND_NAME}" >> "${HAPROXY_MAP_FILE}"

###############################################################################
# Validate HAProxy
###############################################################################

run "Validating HAProxy configuration" haproxy -c -f "${HAPROXY_CFG}" -f "${HAPROXY_CONF_DIR}"

###############################################################################
# Restart HAProxy
###############################################################################

run "Stopping HAProxy" systemctl stop haproxy
run "Starting HAProxy" systemctl start haproxy
run "Enabling HAProxy" systemctl enable haproxy

###############################################################################
# Update /etc/hosts entry
###############################################################################

SYSTEM_IP="$(hostname -I | awk '{print $1}')"

log "Adding PeerJS Portal host entry to /etc/hosts"

grep -qE "^[[:space:]]*${SYSTEM_IP}[[:space:]]+${PEERJS_PORTAL_URL}$" /etc/hosts || \
    echo "${SYSTEM_IP} ${PEERJS_PORTAL_URL}" >> /etc/hosts

###############################################################################
# Completion
###############################################################################

unset GIT_SSH_COMMAND
log "PeerJS deployment completed successfully."
