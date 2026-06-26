#!/bin/bash

###############################################################################
# Description:
#   Deploys PeerJS and integrates it with HAProxy:
#     - Loads configuration from answers.txt
#     - Installs Node.js 24
#     - Installs PM2
#     - Configures PM2 startup
#     - Deploys PeerJS application from Bitbucket
#     - Installs Node dependencies
#     - Starts PeerJS under PM2
#     - Persists PM2 configuration
#     - Installs TLS certificate
#     - Renders HAProxy backend configuration
#     - Updates HAProxy hosts.map
#     - Validates HAProxy configuration
#     - Restarts HAProxy
#     - Updates /etc/hosts
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

BITBUCKET_KEY="${SCRIPT_DIR}/files/bitbucket"

PEERJS_REPO="git@bitbucket.org:teamsignifi/peerjs-server.git"
PEERJS_BRANCH="master"

PEERJS_DIR="/var/www/${PEERJS_PORTAL_URL}"

PEM_FILE="${SCRIPT_DIR}/files/haproxy.pem"

PEERJS_TEMPLATE="${SCRIPT_DIR}/templates/peerjs_backend.j2"
PEERJS_HAPROXY_CFG="/etc/haproxy/conf.d/${PEERJS_PORTAL_URL}_backend.cfg"

HOSTS_MAP="/etc/haproxy/maps/hosts.map"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
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
    "${PEM_FILE}"
    "${PEERJS_TEMPLATE}"
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

for cmd in git npm node pm2 haproxy systemctl python3; do
    command -v "${cmd}" >/dev/null 2>&1 || true
done

###############################################################################
# Install Node.js 24
###############################################################################

run "Refreshing DNF package cache" \
    dnf makecache

run "Resetting Node.js module" \
    dnf module reset nodejs -y

run "Enabling Node.js 24 module stream" \
    dnf module enable nodejs:24 -y

run "Installing Node.js" \
    dnf install -y nodejs

###############################################################################
# Install PM2
###############################################################################

run "Installing PM2 globally" \
    npm install -g pm2

###############################################################################
# Configure PM2 startup
###############################################################################

run "Configuring PM2 startup" \
    pm2 startup systemd -u root --hp /root

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

run "Installing PeerJS dependencies" \
    bash -c "cd '${PEERJS_DIR}' && npm ci"

###############################################################################
# Application permissions
###############################################################################

run "Setting PeerJS ownership" \
    chown -R root:root "${PEERJS_DIR}"

run "Setting PeerJS permissions" \
    chmod -R 0755 "${PEERJS_DIR}"

###############################################################################
# PM2 deployment
###############################################################################

if pm2 list | grep -q 'peerjs'; then

    run "Restarting PeerJS PM2 application" \
        pm2 restart peerjs

else

    run "Starting PeerJS PM2 application" \
        bash -c "cd '${PEERJS_DIR}' && pm2 start app.js --name peerjs"

fi

run "Persisting PM2 process list" \
    bash -c "cd '${PEERJS_DIR}' && pm2 save"

###############################################################################
# Install certificate
###############################################################################

run "Installing PeerJS TLS certificate" \
    cp -f \
        "${PEM_FILE}" \
        "/etc/haproxy/certs/${PEERJS_PORTAL_URL}.pem"

chmod 0600 "/etc/haproxy/certs/${PEERJS_PORTAL_URL}.pem"
chown root:root "/etc/haproxy/certs/${PEERJS_PORTAL_URL}.pem"

###############################################################################
# Install Jinja2
###############################################################################

run "Installing python3-jinja2" \
    dnf install -y python3-jinja2

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

with open("${PEERJS_HAPROXY_CFG}", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${PEERJS_HAPROXY_CFG}"
chown root:root "${PEERJS_HAPROXY_CFG}"

###############################################################################
# Remove Jinja2
###############################################################################

run "Removing python3-jinja2" \
    dnf remove -y python3-jinja2

###############################################################################
# Update HAProxy hosts.map
###############################################################################

PEERJS_BACKEND_NAME="$(
    echo "${PEERJS_PORTAL_URL}" \
        | sed 's/[.-]/_/g'
)_backend"

MAP_ENTRY="${PEERJS_PORTAL_URL} ${PEERJS_BACKEND_NAME}"

if ! grep -Fxq "${MAP_ENTRY}" "${HOSTS_MAP}"; then

    log "Adding PeerJS host mapping"

    echo "${MAP_ENTRY}" >> "${HOSTS_MAP}"

else

    log "PeerJS host mapping already exists"

fi

###############################################################################
# Validate HAProxy
###############################################################################

run "Validating HAProxy configuration" \
    haproxy -c \
        -f /etc/haproxy/haproxy.cfg \
        -f /etc/haproxy/conf.d

###############################################################################
# Restart HAProxy
###############################################################################

run "Stopping HAProxy service" \
    systemctl stop haproxy

run "Disabling HAProxy service" \
    systemctl disable haproxy

run "Starting HAProxy service" \
    systemctl start haproxy

run "Enabling HAProxy service" \
    systemctl enable haproxy

###############################################################################
# Update /etc/hosts
###############################################################################

HOST_IP="$(
    ip route get 1.1.1.1 \
        | awk '{
            for(i=1;i<=NF;i++)
                if($i=="src") {
                    print $(i+1)
                    exit
                }
        }'
)"

HOST_ENTRY="${HOST_IP} ${PEERJS_PORTAL_URL}"

if ! grep -Eq "^[[:space:]]*${HOST_IP}[[:space:]]+${PEERJS_PORTAL_URL}$" /etc/hosts; then

    log "Adding PeerJS host entry to /etc/hosts"

    echo "${HOST_ENTRY}" >> /etc/hosts

else

    log "PeerJS host entry already exists"

fi

###############################################################################
# Completion
###############################################################################

log "PeerJS deployment completed successfully."
