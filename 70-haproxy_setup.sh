#!/bin/bash

###############################################################################
# Description:
#   Configures HAProxy and rsyslog for the Vision application on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt
#     - Validates required variables, arrays, and files
#     - Cleans and rebuilds the DNF package metadata cache
#     - Installs missing HAProxy and rsyslog packages
#     - Backs up the existing HAProxy configuration when present
#     - Creates and enforces HAProxy directory structure, ownership, and permissions
#     - Creates and enforces the HAProxy hosts.map file
#     - Configures rsyslog for HAProxy UDP/local0 logging
#     - Ensures the HAProxy log file exists with proper ownership and permissions
#     - Deploys HAProxy base configuration files only when missing or changed
#     - Installs Jinja2 to render HAProxy configuration templates
#     - Renders HAProxy global frontend, global backend, and portal backend configs
#     - Deploys rendered HAProxy configuration files only when missing or changed
#     - Removes Jinja2 after rendering HAProxy configuration
#     - Installs the TLS certificate only when missing or changed
#     - Escapes the portal URL for safe regex-based file updates
#     - Updates HAProxy hosts.map with the portal backend routing entry
#     - Validates the HAProxy configuration
#     - Restarts and enables the HAProxy service
#     - Adds or updates the portal entry in /etc/hosts
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
CERT_DEST="${HAPROXY_CERT_DIR}/${PORTAL_URL}.pem"

GLOBAL_FRONTEND_TEMPLATE="${SCRIPT_DIR}/templates/global_frontend.j2"
GLOBAL_BACKEND_SRC="${SCRIPT_DIR}/templates/global_backend.j2"
PORTAL_BACKEND_TEMPLATE="${SCRIPT_DIR}/templates/portal_backend.j2"

UNKNOWN_BACKEND_SRC="${SCRIPT_DIR}/files/haproxy_config/unknown_host_backend.cfg"
HAPROXY_MAIN_SRC="${SCRIPT_DIR}/files/haproxy_config/haproxy.cfg"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    PORTAL_URL
    CERT_PATH
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined or is empty"
        exit 1
    fi
done

###############################################################################
# Validate required arrays
###############################################################################

if [[ "${#HAPROXY_ALLOWED_STATS_IPS[@]}" -eq 0 ]]; then
    error "Required array 'HAPROXY_ALLOWED_STATS_IPS' is not defined or is empty"
    exit 1
fi

###############################################################################
# Validate required files
###############################################################################

REQUIRED_FILES=(
    "${CERT_PATH}"
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
# Refresh DNF Metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# Install packages
###############################################################################

REQUIRED_PACKAGES=(
    haproxy
    rsyslog
)

MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    if rpm -q "${package}" >/dev/null 2>&1; then
        log "Package already installed: ${package}"
    else
        MISSING_PACKAGES+=("${package}")
    fi
done

if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then

    run "Installing missing HAProxy and rsyslog packages" \
        dnf install -y --refresh "${MISSING_PACKAGES[@]}"

else

    log "All HAProxy and rsyslog packages are already installed"

fi

###############################################################################
# Backup HAProxy configuration
###############################################################################

backup_file_if_needed "${HAPROXY_CFG}"

###############################################################################
# Create directory structure
###############################################################################

run "Creating HAProxy configuration directory" mkdir -p "${HAPROXY_CONF_DIR}"
run "Creating HAProxy map directory" mkdir -p "${HAPROXY_MAP_DIR}"
run "Creating HAProxy certificate directory" mkdir -p "${HAPROXY_CERT_DIR}"

run "Setting HAProxy configuration directory ownership" chown root:root "${HAPROXY_CONF_DIR}"
run "Setting HAProxy map directory ownership" chown root:root "${HAPROXY_MAP_DIR}"
run "Setting HAProxy certificate directory ownership" chown root:root "${HAPROXY_CERT_DIR}"

run "Setting HAProxy configuration directory permissions" chmod 0755 "${HAPROXY_CONF_DIR}"
run "Setting HAProxy map directory permissions" chmod 0755 "${HAPROXY_MAP_DIR}"
run "Setting HAProxy certificate directory permissions" chmod 0750 "${HAPROXY_CERT_DIR}"

###############################################################################
# Creating hosts.map file
###############################################################################

run "Creating HAProxy hosts map file" touch "${HAPROXY_MAP_FILE}"
run "Setting HAProxy hosts map ownership" chown root:root "${HAPROXY_MAP_FILE}"
run "Setting HAProxy hosts map permissions" chmod 0644 "${HAPROXY_MAP_FILE}"

###############################################################################
# rsyslog configuration
###############################################################################

log "Creating rsyslog HAProxy configuration for HAProxy logging"

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

run "Setting rsyslog HAProxy configuration permissions" chmod 0644 /etc/rsyslog.d/49-haproxy.conf
run "Setting rsyslog HAProxy configuration ownership" chown root:root /etc/rsyslog.d/49-haproxy.conf

run "Ensuring HAProxy log file exists" touch /var/log/haproxy.log
run "Setting HAProxy log file permissions" chmod 0640 /var/log/haproxy.log
run "Setting HAProxy log file ownership" chown root:root /var/log/haproxy.log

run "Restarting rsyslog service" systemctl restart rsyslog

###############################################################################
# Deploy HAProxy base configs
###############################################################################

UNKNOWN_BACKEND_DEST="${HAPROXY_CONF_DIR}/02-unknown-host.cfg"

if [[ -f "${HAPROXY_CFG}" ]] && cmp -s "${HAPROXY_MAIN_SRC}" "${HAPROXY_CFG}"; then

    log "HAProxy default configuration already up to date: ${HAPROXY_CFG}"

else

    run "Deploying HAProxy default configuration file" cp -f \
        "${HAPROXY_MAIN_SRC}" "${HAPROXY_CFG}"

fi

run "Setting HAProxy default configuration permissions" chmod 0644 "${HAPROXY_CFG}"
run "Setting HAProxy default configuration ownership" chown root:root "${HAPROXY_CFG}"

if [[ -f "${UNKNOWN_BACKEND_DEST}" ]] && cmp -s "${UNKNOWN_BACKEND_SRC}" "${UNKNOWN_BACKEND_DEST}"; then

    log "HAProxy unknown host backend configuration already up to date: ${UNKNOWN_BACKEND_DEST}"

else

    run "Deploying HAProxy unknown host backend configuration file" cp -f \
        "${UNKNOWN_BACKEND_SRC}" "${UNKNOWN_BACKEND_DEST}"

fi

run "Setting HAProxy unknown host backend configuration permissions" chmod 0644 "${UNKNOWN_BACKEND_DEST}"
run "Setting HAProxy unknown host backend configuration ownership" chown root:root "${UNKNOWN_BACKEND_DEST}"

###############################################################################
# Jinja2 install
###############################################################################

run "Installing python3-jinja2" dnf install -y --refresh python3-jinja2

###############################################################################
# Render global frontend config
###############################################################################

GLOBAL_FRONTEND_DEST="${HAPROXY_CONF_DIR}/00-global_frontend.cfg"

log "Rendering Global frontend configuration"

TEMP_GLOBAL_FRONTEND_CONFIG="$(mktemp)"

python3 <<EOF
from jinja2 import Template

with open("${GLOBAL_FRONTEND_TEMPLATE}") as f:
    template = Template(f.read())

allowed_ips = "${HAPROXY_ALLOWED_STATS_IPS[*]}".split()

rendered = template.render(
    HAPROXY_ALLOWED_STATS_IPS=allowed_ips
)

rendered = rendered.rstrip("\n") + "\n"

with open("${TEMP_GLOBAL_FRONTEND_CONFIG}", "w") as f:
    f.write(rendered)
EOF

if [[ -f "${GLOBAL_FRONTEND_DEST}" ]] && cmp -s "${TEMP_GLOBAL_FRONTEND_CONFIG}" "${GLOBAL_FRONTEND_DEST}"; then

    log "Global frontend configuration already up to date: ${GLOBAL_FRONTEND_DEST}"
    rm -f "${TEMP_GLOBAL_FRONTEND_CONFIG}"

else

    log "Deploying Global frontend configuration: ${GLOBAL_FRONTEND_DEST}"

    cp -f "${TEMP_GLOBAL_FRONTEND_CONFIG}" "${GLOBAL_FRONTEND_DEST}"
    rm -f "${TEMP_GLOBAL_FRONTEND_CONFIG}"

fi

run "Setting Global frontend configuration permissions" chmod 0644 "${GLOBAL_FRONTEND_DEST}"
run "Setting Global frontend configuration ownership" chown root:root "${GLOBAL_FRONTEND_DEST}"

###############################################################################
# Render global backend configuration
###############################################################################

GLOBAL_BACKEND_DEST="${HAPROXY_CONF_DIR}/01-global_stats.cfg"

log "Rendering Global backend configuration"

TEMP_GLOBAL_BACKEND_CONFIG="$(mktemp)"

python3 <<EOF
from jinja2 import Template

with open("${GLOBAL_BACKEND_SRC}") as f:
    template = Template(f.read())

rendered = template.render(
    PORTAL_URL="${PORTAL_URL}"
)

rendered = rendered.rstrip("\n") + "\n"

with open("${TEMP_GLOBAL_BACKEND_CONFIG}", "w") as f:
    f.write(rendered)
EOF

if [[ -f "${GLOBAL_BACKEND_DEST}" ]] && cmp -s "${TEMP_GLOBAL_BACKEND_CONFIG}" "${GLOBAL_BACKEND_DEST}"; then

    log "Global backend configuration already up to date: ${GLOBAL_BACKEND_DEST}"
    rm -f "${TEMP_GLOBAL_BACKEND_CONFIG}"

else

    log "Deploying Global backend configuration: ${GLOBAL_BACKEND_DEST}"

    cp -f "${TEMP_GLOBAL_BACKEND_CONFIG}" "${GLOBAL_BACKEND_DEST}"
    rm -f "${TEMP_GLOBAL_BACKEND_CONFIG}"

fi

run "Setting Global backend configuration permissions" chmod 0644 "${GLOBAL_BACKEND_DEST}"
run "Setting Global backend configuration ownership" chown root:root "${GLOBAL_BACKEND_DEST}"

###############################################################################
# Render portal backend config
###############################################################################

PORTAL_BACKEND_DEST="${HAPROXY_CONF_DIR}/${PORTAL_URL}_backend.cfg"

log "Rendering Portal backend configuration"

TEMP_PORTAL_BACKEND_CONFIG="$(mktemp)"

python3 <<EOF
from jinja2 import Template

with open("${PORTAL_BACKEND_TEMPLATE}") as f:
    tpl = Template(f.read())

rendered = tpl.render(portal_url="${PORTAL_URL}")

rendered = rendered.rstrip("\n") + "\n"

with open("${TEMP_PORTAL_BACKEND_CONFIG}", "w") as f:
    f.write(rendered)
EOF

if [[ -f "${PORTAL_BACKEND_DEST}" ]] && cmp -s "${TEMP_PORTAL_BACKEND_CONFIG}" "${PORTAL_BACKEND_DEST}"; then

    log "Portal backend configuration already up to date: ${PORTAL_BACKEND_DEST}"
    rm -f "${TEMP_PORTAL_BACKEND_CONFIG}"

else

    log "Deploying Portal backend configuration: ${PORTAL_BACKEND_DEST}"

    cp -f "${TEMP_PORTAL_BACKEND_CONFIG}" "${PORTAL_BACKEND_DEST}"
    rm -f "${TEMP_PORTAL_BACKEND_CONFIG}"

fi

run "Setting Portal backend configuration permissions" chmod 0644 "${PORTAL_BACKEND_DEST}"
run "Setting Portal backend configuration ownership" chown root:root "${PORTAL_BACKEND_DEST}"

###############################################################################
# Remove Jinja2
###############################################################################

run "Removing python3-jinja2" dnf remove -y python3-jinja2

###############################################################################
# Install TLS certificate
###############################################################################

if [[ -f "${CERT_DEST}" ]] && cmp -s "${CERT_PATH}" "${CERT_DEST}"; then

    log "TLS certificate already up to date: ${CERT_DEST}"

else

    run "Installing TLS certificate" cp -f "${CERT_PATH}" "${CERT_DEST}"

fi

run "Setting TLS certificate permissions" chmod 0600 "${CERT_DEST}"
run "Setting TLS certificate ownership" chown root:root "${CERT_DEST}"

###############################################################################
# Escape portal URL for regex operations
###############################################################################

PORTAL_URL_REGEX="$(printf '%s\n' "${PORTAL_URL}" | sed 's/[][\/.^$*+?{}|()]/\\&/g')"

###############################################################################
# Update hosts.map entry
###############################################################################

BACKEND_NAME="${PORTAL_URL//[-.]/_}_backend"

log "Ensuring ${PORTAL_URL} is mapped to ${BACKEND_NAME} in HAProxy backend map"

if grep -qE "^${PORTAL_URL_REGEX}[[:space:]]+${BACKEND_NAME}$" "${HAPROXY_MAP_FILE}"; then

    log "HAProxy backend map entry already exists: ${PORTAL_URL} ${BACKEND_NAME}"

else

    sed -i "\|^${PORTAL_URL_REGEX}[[:space:]]|d" "${HAPROXY_MAP_FILE}"
    echo "${PORTAL_URL} ${BACKEND_NAME}" >> "${HAPROXY_MAP_FILE}"

fi

###############################################################################
# Validate HAProxy
###############################################################################

run "Validating HAProxy configuration" haproxy -c -f "${HAPROXY_CFG}" -f "${HAPROXY_CONF_DIR}"

###############################################################################
# Restart HAProxy
###############################################################################

run "Stopping HAProxy" systemctl stop haproxy
run "Enabling HAProxy" systemctl enable --now haproxy

###############################################################################
# Update /etc/hosts entry
###############################################################################

SYSTEM_IP="$(hostname -I | awk '{print $1}')"

log "Ensuring Portal host entry exists in /etc/hosts"

if grep -qE "^[[:space:]]*${SYSTEM_IP}[[:space:]]+${PORTAL_URL_REGEX}$" /etc/hosts; then

    log "/etc/hosts entry already exists: ${SYSTEM_IP} ${PORTAL_URL}"

else

    sed -i "\|[[:space:]]${PORTAL_URL_REGEX}$|d" /etc/hosts
    echo "${SYSTEM_IP} ${PORTAL_URL}" >> /etc/hosts

fi

###############################################################################
# Completion
###############################################################################

unset PORTAL_URL
unset SYSTEM_IP
unset BACKEND_NAME
unset PORTAL_URL_REGEX
log "HAProxy configuration completed successfully."
