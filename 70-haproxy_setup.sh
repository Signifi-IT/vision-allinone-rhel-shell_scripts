#!/bin/bash

###############################################################################
# Description:
#   Configures HAProxy and rsyslog for the Vision application on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Refreshes DNF metadata and installs HAProxy and rsyslog packages
#     - Configures custom rsyslog for HAProxy logging
#     - Prepares HAProxy directory structure
#     - Removes default HAProxy configuration file and deploys new configs
#     - Installs Jinja2 to render templates
#     - Generates HAProxy configuration files using Jinja2 templates
#     - Removes Jinja2 after rendering configurations
#     - Installs TLS certificate
#     - Maintains HAProxy host mapping file (hosts.map) with backend routing entries
#     - Adds portal entry to /etc/hosts
#     - Validates HAProxy configuration
#     - Restarts, enables, and activates HAProxy service
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

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_MAP_DIR="/etc/haproxy/maps"

HAPROXY_MAP_FILE="${HAPROXY_MAP_DIR}/hosts.map"

HAPROXY_CERT_DIR="/etc/haproxy/certs"
CERT_SOURCE="${CERT_PATH}"
CERT_DEST="${HAPROXY_CERT_DIR}/${PORTAL_URL}.pem"

GLOBAL_FRONTEND_TEMPLATE="${SCRIPT_DIR}/templates/global_frontend.j2"
PORTAL_BACKEND_TEMPLATE="${SCRIPT_DIR}/templates/portal_backend.j2"

GLOBAL_BACKEND_SRC="${SCRIPT_DIR}/files/haproxy_config/global_backend.cfg"
UNKNOWN_BACKEND_SRC="${SCRIPT_DIR}/files/haproxy_config/unknown_host_backend.cfg"
HAPROXY_MAIN_SRC="${SCRIPT_DIR}/files/haproxy_config/haproxy.cfg"

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
# Backup helper
###############################################################################

backup_file_if_needed() {
    local file="$1"
    local backup="${file}.bak"

    if [[ -f "${file}" ]] && [[ ! -f "${backup}" ]]; then
        log "Creating backup: ${backup}"
        cp -p "${file}" "${backup}"
    else
        log "Backup already exists: ${backup}"
    fi
}

###############################################################################
# Refresh DNF Metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# Install packages
###############################################################################

run "Installing HAProxy and rsyslog" dnf install -y haproxy-2.8.14-1.el9_7.1.x86_64 rsyslog

###############################################################################
# Backup and remove default config
###############################################################################

backup_file_if_needed "${HAPROXY_CFG}"

run "Removing default HAProxy configuration" rm -f "${HAPROXY_CFG}"

###############################################################################
# Create directory structure
###############################################################################

run "Creating HAProxy directories" mkdir -p \
    "${HAPROXY_CERT_DIR}" \
    "${HAPROXY_CONF_DIR}" \
    "${HAPROXY_MAP_DIR}"

chmod 0750 "${HAPROXY_CERT_DIR}"
chown root:root "${HAPROXY_CERT_DIR}"

chmod 0755 "${HAPROXY_CONF_DIR}"
chown root:root "${HAPROXY_CONF_DIR}"

chmod 0755 "${HAPROXY_MAP_DIR}"
chown root:root "${HAPROXY_MAP_DIR}"

###############################################################################
# Creating hosts.map file
###############################################################################

run "Creating hosts.map file" touch "${HAPROXY_MAP_FILE}"

chmod 0644 "${HAPROXY_MAP_FILE}"
chown root:root "${HAPROXY_MAP_FILE}"

###############################################################################
# rsyslog configuration
###############################################################################

run "Removing default rsyslog HAProxy configuration file" rm -f /etc/rsyslog.d/49-haproxy.conf

log "Creating rsyslog HAProxy configurtion for HAProxy logging"
cat > /etc/rsyslog.d/49-haproxy.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")

if (
    $programname == "haproxy" and
    $syslogfacility-text == "local0"
) then {
    action(type="omfile" file="/var/log/haproxy.log")
    stop
}
EOF

chmod 0644 "/etc/rsyslog.d/49-haproxy.conf"
chown root:root "/etc/rsyslog.d/49-haproxy.conf"

run "Creating HAProxy log file" touch /var/log/haproxy.log
chmod 0640 /var/log/haproxy.log
chown root:root /var/log/haproxy.log

run "Restarting rsyslog service" systemctl restart rsyslog

###############################################################################
# Deploy HAProxy base configs
###############################################################################

run "Deploying HAProxy default configuration file" cp -f \
    "${HAPROXY_MAIN_SRC}" \
    "${HAPROXY_CFG}"
   
chmod 0644 "${HAPROXY_CFG}"
chown root:root "${HAPROXY_CFG}"

run "Deploying HAProxy unknown host backend configuration file" cp -f \
    "${UNKNOWN_BACKEND_SRC}" \
    "${HAPROXY_CONF_DIR}/02-unknown-host.cfg"

chmod 0644 "${HAPROXY_CONF_DIR}/02-unknown-host.cfg"
chown root:root "${HAPROXY_CONF_DIR}/02-unknown-host.cfg"

###############################################################################
# Jinja2 install
###############################################################################

run "Installing python3-jinja2" dnf install -y python3-jinja2

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

rendered = rendered.rstrip("\n") + "\n"

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

rendered = rendered.rstrip("\n") + "\n"

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

rendered = rendered.rstrip("\n") + "\n"

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

run "Installing TLS certificate" cp -f "${CERT_SOURCE}" "${CERT_DEST}"

chmod 0600 "${CERT_DEST}"
chown root:root "${CERT_DEST}"

###############################################################################
# Update hosts.map entry
###############################################################################

BACKEND_NAME="${PORTAL_URL//[-.]/_}_backend"

log "Adding ${PORTAL_URL} to HAProxy backend map as ${BACKEND_NAME}"

grep -q "${PORTAL_URL}" "${HAPROXY_MAP_FILE}" || \
    echo "${PORTAL_URL} ${BACKEND_NAME}" >> "${HAPROXY_MAP_FILE}"

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

log "Adding Portal host entry to /etc/hosts"

grep -qE "^[[:space:]]*${SYSTEM_IP}[[:space:]]+${PORTAL_URL}$" /etc/hosts || \
    echo "${SYSTEM_IP} ${PORTAL_URL}" >> /etc/hosts

###############################################################################
# Completion
###############################################################################

log "HAProxy configuration completed successfully."
