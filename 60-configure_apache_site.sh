#!/bin/bash

###############################################################################
# Description:
#   Configures Apache HTTPD for the Vision application on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt and validates required variables
#     - Applies recursive application ownership and permission settings
#     - Removes default Apache configuration files and unused modules
#     - Configures mod_status and Apache security hardening directives
#     - Configures Apache listener to listen on 127.0.0.1:7080 by updating Listen directives
#     - Configures global ServerName
#     - Installs Jinja2 to render virtual host configuration
#     - Generates Apache virtual host configuration from Jinja2 template
#     - Removes Jinja2 after rendering
#     - Creates and configures application-specific Apache log directory
#     - Comments default DocumentRoot in main Apache configuration
#     - Configures SELinux HTTP port mapping for 7080
#     - Validates Apache configuration syntax before restart
#     - Enables and restarts Apache HTTPD service
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

APP_DIR="/var/www/${PORTAL_URL}"

TEMPLATE_FILE="${SCRIPT_DIR}/templates/site_template.j2"
SITE_CONFIG="/etc/httpd/conf.d/${PORTAL_URL}.conf"

STATUS_CONF="/etc/httpd/conf.d/status.conf"
SECURITY_CONF="/etc/httpd/conf.d/security.conf"

HTTPD_CONF="/etc/httpd/conf/httpd.conf"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    PORTAL_URL
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined"
        exit 1
    fi
done

###############################################################################
# Validate template
###############################################################################

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    error "Template not found: ${TEMPLATE_FILE}"
    exit 1
fi

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
# Application permissions
###############################################################################

run "Setting application permissions" \
    find "${APP_DIR}" -type d -exec chmod 0755 {} + && \
    find "${APP_DIR}" -type f -exec chmod 0644 {} +

run "Setting application ownership" chown -R root:root "${APP_DIR}"

###############################################################################
# Remove default Apache configuration
###############################################################################

DEFAULT_CONFS=(
    welcome.conf
    autoindex.conf
    userdir.conf
    status.conf
    security.conf
)

for file in "${DEFAULT_CONFS[@]}"; do

    if [[ -f "/etc/httpd/conf.d/${file}" ]]; then

        run "Removing ${file}" \
            rm -f "/etc/httpd/conf.d/${file}"

    fi

done

###############################################################################
# mod_status configuration
###############################################################################

log "Creating mod_status configuration"

cat > "${STATUS_CONF}" <<'EOF'
ExtendedStatus On

<IfModule mod_proxy.c>
    # Show Proxy LoadBalancer status in mod_status
    ProxyStatus On
</IfModule>
EOF

chmod 0644 "${STATUS_CONF}"
chown root:root "${STATUS_CONF}"

###############################################################################
# Apache listener configuration
###############################################################################

backup_file_if_needed "${HTTPD_CONF}"

run "Configure Apache port to listen on 7080" \
    sed -ri 's|^[[:space:]]*Listen[[:space:]].*|Listen 127.0.0.1:7080|' "${HTTPD_CONF}"

###############################################################################
# Apache security configuration
###############################################################################

log "Creating Apache security configuration"

cat > "${SECURITY_CONF}" <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF

chmod 0644 "${SECURITY_CONF}"
chown root:root "${SECURITY_CONF}"

###############################################################################
# Configuring ServerName globally
###############################################################################

log "Ensuring Global Apache ServerName is configured"

if ! grep -q '^ServerName localhost$' "${HTTPD_CONF}"; then
    echo "ServerName localhost" >> "${HTTPD_CONF}"
fi

###############################################################################
# Install Jinja2
###############################################################################

run "Installing python3-jinja2" dnf install -y python3-jinja2

###############################################################################
# Render virtual host configuration
###############################################################################

log "Rendering Apache virtual host configuration"

export PORTAL_URL

ALLOWED_IPS="$(printf '%s\n' "${ALLOWED_SERVER_STATUS_IPS[@]}")"
export ALLOWED_IPS

python3 <<EOF
from jinja2 import Template

with open("${TEMPLATE_FILE}") as f:
    template = Template(f.read())

rendered = template.render(
    portal_url="${PORTAL_URL}",
    allowed_server_status_ips="""${ALLOWED_IPS}""".splitlines()
)

with open("${SITE_CONFIG}", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${SITE_CONFIG}"
chown root:root "${SITE_CONFIG}"

###############################################################################
# Remove Jinja2
###############################################################################

run "Removing python3-jinja2" dnf remove -y python3-jinja2

###############################################################################
# Apache log directory
###############################################################################

run "Creating Apache log directory" mkdir -p "/var/log/httpd/${PORTAL_URL}"

run "Setting Apache log directory ownership" chown root:root "/var/log/httpd/${PORTAL_URL}"

run "Setting Apache log directory permissions" chmod 0755 "/var/log/httpd/${PORTAL_URL}"

###############################################################################
# Comment default DocumentRoot
###############################################################################

run "Commenting the default Apache DocumentRoot" \
    sed -ri 's|^(DocumentRoot[[:space:]]+"/var/www/html")|# \1|' "${HTTPD_CONF}"

###############################################################################
# SELinux port
###############################################################################

if ! semanage port -l | grep -qE '^http_port_t.*\b7080\b'; then

    run "Adding SELinux HTTP port 7080" semanage port -a -t http_port_t -p tcp 7080

else

    log "SELinux HTTP port 7080 already configured"

fi

###############################################################################
# Validate Apache
###############################################################################

run "Validating Apache configuration" apachectl configtest

###############################################################################
# Enable and restart Apache
###############################################################################

run "Enabling HTTPD service" systemctl enable httpd

run "Restarting HTTPD service" systemctl restart httpd

###############################################################################
# Completion
###############################################################################

unset PORTAL_URL
unset ALLOWED_IPS
log "Apache configuration completed successfully."
