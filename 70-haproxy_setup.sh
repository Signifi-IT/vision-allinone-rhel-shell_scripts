#!/bin/bash

###############################################################################
# Description:
#   Configures HAProxy and rsyslog for Vision application:
#     - Installs required packages
#     - Configures rsyslog logging
#     - Prepares HAProxy directory structure
#     - Deploys HAProxy configuration files
#     - Renders Jinja2-based HAProxy templates
#     - Installs TLS certificate
#     - Configures hosts mapping and /etc/hosts entries
#     - Validates and restarts HAProxy service
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
source "${CONFIG_FILE}"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    PORTAL_URL
    CERT_PATH
    HAPROXY_ALLOWED_STATS_IPS
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined"
        exit 1
    fi
done

###############################################################################
# Constants
###############################################################################

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

HAPROXY_CERT_DIR="/etc/haproxy/certs"
HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_MAP_DIR="/etc/haproxy/maps"

HAPROXY_MAP_FILE="${HAPROXY_MAP_DIR}/hosts.map"

CERT_SOURCE="${SCRIPT_DIR}/${CERT_PATH}"
CERT_DEST="${HAPROXY_CERT_DIR}/${PORTAL_URL}.pem"

GLOBAL_FRONTEND_TEMPLATE="${SCRIPT_DIR}/templates/global_frontend.j2"
PORTAL_BACKEND_TEMPLATE="${SCRIPT_DIR}/templates/portal_backend.j2"

GLOBAL_BACKEND_SRC="${SCRIPT_DIR}/files/haproxy_config/global_backend.cfg"
UNKNOWN_BACKEND_SRC="${SCRIPT_DIR}/files/haproxy_config/unknown_host_backend.cfg"
HAPROXY_MAIN_SRC="${SCRIPT_DIR}/files/haproxy_config/haproxy.cfg"

###############################################################################
# Install packages
###############################################################################

run "Installing HAProxy and rsyslog" \
    dnf install -y haproxy rsyslog

###############################################################################
# Backup and remove default config
###############################################################################

if [[ -f "${HAPROXY_CFG}" ]]; then
    run "Backing up HAProxy configuration" cp -f "${HAPROXY_CFG}" "${HAPROXY_CFG}.bak"
    run "Removing default HAProxy configuration" rm -f "${HAPROXY_CFG}"
fi

chmod 0644 "${HAPROXY_CFG}.bak"
chown root:root "${HAPROXY_CFG}.bak"

###############################################################################
# Create directory structure
###############################################################################

run "Creating HAProxy directories" mkdir -p \
    "${HAPROXY_CERT_DIR}" \
    "${HAPROXY_CONF_DIR}" \
    "${HAPROXY_MAP_DIR}"

chmod 0750 "${HAPROXY_CERT_DIR}"
chmod 0755 "${HAPROXY_CONF_DIR}"
chmod 0755 "${HAPROXY_MAP_DIR}"

###############################################################################
# hosts.map
###############################################################################

touch "${HAPROXY_MAP_FILE}"
chmod 0644 "${HAPROXY_MAP_FILE}"
chown root:root "${HAPROXY_MAP_FILE}"

###############################################################################
# rsyslog configuration
###############################################################################

rm -f /etc/rsyslog.d/49-haproxy.conf

cat > /etc/rsyslog.d/49-haproxy.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")

local0.*    /var/log/haproxy.log
local1.*    /var/log/haproxy.log
local2.*    /var/log/haproxy.log
& stop
EOF

chmod 0644 "/etc/rsyslog.d/49-haproxy.conf"
chown root:root "/etc/rsyslog.d/49-haproxy.conf"

touch /var/log/haproxy.log
chmod 0640 /var/log/haproxy.log
chown root:root /var/log/haproxy.log

run "Restarting rsyslog" systemctl restart rsyslog

###############################################################################
# Deploy HAProxy base configs
###############################################################################

run "Deploying HAProxy base configuration" cp -f \
    "${HAPROXY_MAIN_SRC}" \
    "${HAPROXY_CFG}"
   
chmod 0644 "${HAPROXY_CFG}"
chown root:root "${HAPROXY_CFG}"

run "Deploying unknown host backend" cp -f \
    "${UNKNOWN_BACKEND_SRC}" \
    "${HAPROXY_CONF_DIR}/02-unknown-host.cfg"

chmod 0644 "${HAPROXY_CONF_DIR}/02-unknown-host.cfg"
chown root:root "${HAPROXY_CONF_DIR}/02-unknown-host.cfg"

###############################################################################
# Jinja2 install (temporary)
###############################################################################

run "Installing python3-jinja2" \
    dnf install -y python3-jinja2

###############################################################################
# Render global frontend config
###############################################################################

log "Rendering Global frontend configuration"

python3 <<EOF
from jinja2 import Template

with open("${SCRIPT_DIR}/templates/global_frontend.j2") as f:
    template = Template(f.read())

allowed_ips = "${HAPROXY_ALLOWED_STATS_IPS[*]}".split()

rendered = template.render(
    HAPROXY_ALLOWED_STATS_IPS=allowed_ips
)

with open("${HAPROXY_CONF_DIR}/00-global_frontend.cfg", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${HAPROXY_CONF_DIR}/00-global_frontend.cfg"
chown root:root "${HAPROXY_CONF_DIR}/00-global_frontend.cfg"

###############################################################################
# Render global backend configuration
###############################################################################

log "Rendering Global backend onfiguration"

python3 <<EOF
from jinja2 import Template

with open("${SCRIPT_DIR}/templates/global_backend.j2") as f:
    template = Template(f.read())

rendered = template.render(
    PORTAL_URL="${PORTAL_URL}"
)

with open("${HAPROXY_CONF_DIR}/01-global_stats.cfg", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${HAPROXY_CONF_DIR}/01-global_stats.cfg"
chown root:root "${HAPROXY_CONF_DIR}/01-global_stats.cfg"

###############################################################################
# Render portal backend config
###############################################################################

log "Rendering Portal backend configuration"

python3 <<EOF
from jinja2 import Template

with open("${PORTAL_BACKEND_TEMPLATE}") as f:
    tpl = Template(f.read())

rendered = tpl.render(portal_url="${PORTAL_URL}")

with open("${HAPROXY_CONF_DIR}/${PORTAL_URL}_backend.cfg", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${HAPROXY_CONF_DIR}/${PORTAL_URL}_backend.cfg"
chown root:root "${HAPROXY_CONF_DIR}/${PORTAL_URL}_backend.cfg"

###############################################################################
# Remove Jinja2
###############################################################################

run "Removing python3-jinja2" dnf remove -y python3-jinja2

###############################################################################
# Install TLS certificate
###############################################################################

run "Installing TLS certificate" cp -f \
    "${CERT_SOURCE}" \
    "${CERT_DEST}"

chmod 0600 "${CERT_DEST}"
chown root:root "${CERT_DEST}"

###############################################################################
# hosts.map entry (regex_replace -> bash replace)
###############################################################################

BACKEND_NAME="${PORTAL_URL//[-.]/_}_backend"

log "Adding ${PORTAL_URL} to HAProxy backend map as ${BACKEND_NAME}"

grep -q "${PORTAL_URL}" "${HAPROXY_MAP_FILE}" || \
    echo "${PORTAL_URL} ${BACKEND_NAME}" >> "${HAPROXY_MAP_FILE}"

###############################################################################
# /etc/hosts entry (manual IP detection)
###############################################################################

SYSTEM_IP="$(hostname -I | awk '{print $1}')"

log "Adding Portal host entry to /etc/hosts"

grep -qE "^[[:space:]]*${SYSTEM_IP}[[:space:]]+${PORTAL_URL}$" /etc/hosts || \
    echo "${SYSTEM_IP} ${PORTAL_URL}" >> /etc/hosts

###############################################################################
# Validate HAProxy
###############################################################################

run "Validating HAProxy configuration" \
    haproxy -c -f "${HAPROXY_CFG}" -f "${HAPROXY_CONF_DIR}"

###############################################################################
# Restart HAProxy
###############################################################################

run "Stopping HAProxy" systemctl stop haproxy
run "Starting HAProxy" systemctl start haproxy
run "Enabling HAProxy" systemctl enable haproxy

###############################################################################
# Completion
###############################################################################

log "HAProxy configuration completed successfully."
