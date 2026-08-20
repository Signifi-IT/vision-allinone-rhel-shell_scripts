#!/bin/bash

###############################################################################
# Description:
#   Adds a new Vision application portal to an already configured application server on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers-add_portal.txt
#     - Validates required variables
#     - Validates required files
#     - Creates application database
#     - Grants required database privileges to application user
#     - Restores application database from backup
#     - Query migration table and logs results for verification
#     - Creates application directory structure under /var/www
#     - Configures Bitbucket SSH key for secure Git access
#     - Clones application, media, API, and mobile repositories from their branches
#     - Deploys media, API, and mobile assets into application directory structure
#     - Creates required application session directories
#     - Removes temporary repository working directories
#     - Installs Jinja2 to render templates
#     - Generates Apache virtual host configuration from Jinja2 template
#     - Creates and configures application-specific Apache log directory
#     - Validates Apache configuration syntax
#     - Enables and restarts Apache HTTPD service
#     - Generates HAProxy configuration files from Jinja2 templates
#     - Removes Jinja2 after rendering templates
#     - Installs TLS certificate
#     - Updates HAProxy host mapping file (hosts.map) with backend routing entries
#     - Validates HAProxy configuration
#     - Restarts and enables HAProxy service
#     - Adds portal entry to /etc/hosts
#     - Configures recursive application ownership and permission settings
#     - Configures SELinux file contexts for the application sessions directory
#     - Configures SELinux file contexts for the application media directory
#     - Applies SELinux contexts recursively using restorecon
#     - Sets writable permissions on the application media directory
#     - Sets writable permissions on the application sessions directory
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
CONFIG_FILE="${SCRIPT_DIR}/answers-add_portal.txt"

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

POSTGRES_PORT="5431"

PSQL="/usr/pgsql-14/bin/psql"
PG_RESTORE="/usr/pgsql-14/bin/pg_restore"
PG_ISREADY="/usr/pgsql-14/bin/pg_isready"

BACKUP_FILE="${BACKUP_FILE_PATH}"

APP_DIR="/var/www/${PORTAL_URL}"
MEDIA_DIR="${APP_DIR}/media"
SESSIONS_DIR="${APP_DIR}/api/application/sessions"

TEMPLATE_FILE="${SCRIPT_DIR}/templates/site_template.j2"
PORTAL_BACKEND_TEMPLATE="${SCRIPT_DIR}/templates/portal_backend.j2"

SITE_CONFIG="/etc/httpd/conf.d/${PORTAL_URL}.conf"

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_MAP_FILE="/etc/haproxy/maps/hosts.map"
HAPROXY_CERT_DIR="/etc/haproxy/certs"

CERT_DEST="${HAPROXY_CERT_DIR}/${PORTAL_URL}.pem"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    POSTGRES_ADMIN_PASSWORD
    APP_DB_USER
    APP_DB_PASSWORD
    APP_DB_NAME
    BACKUP_FILE_PATH
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
    CERT_PATH
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined"
        exit 1
    fi
done

if [[ "${#ALLOWED_SERVER_STATUS_IPS[@]}" -eq 0 ]]; then
    error "Required array 'ALLOWED_SERVER_STATUS_IPS' is not defined or is empty"
    exit 1
fi

###############################################################################
# Validate required files
###############################################################################

REQUIRED_FILES=(
    "${BACKUP_FILE}"
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
# Ensure PostgreSQL running
###############################################################################

log "Waiting for PostgreSQL readiness..."

READY=0

for i in {1..30}; do
    if "${PG_ISREADY}" -h 127.0.0.1 -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
        READY=1
        log "PostgreSQL is ready"
        break
    fi
    sleep 1
done

if [[ "${READY}" -ne 1 ]]; then
    error "PostgreSQL failed to become ready"
    exit 1
fi

###############################################################################
# Create PostgreSQL application database
###############################################################################

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

DB_EXISTS=$(
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d postgres \
        -At \
        -c "SELECT 1 FROM pg_database WHERE datname='${APP_DB_NAME}';"
)

if [[ "${DB_EXISTS}" != "1" ]]; then

    run "Creating application database ${APP_DB_NAME}" \
        "${PSQL}" \
            -h 127.0.0.1 \
            -p "${POSTGRES_PORT}" \
            -U postgres \
            -d postgres \
            -c "CREATE DATABASE \"${APP_DB_NAME}\" OWNER \"${APP_DB_USER}\" ENCODING 'UTF8';"

else

    log "Database '${APP_DB_NAME}' already exists"

fi

###############################################################################
# Grant SUPERUSER privilege to application database user
###############################################################################

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

run "Granting SUPERUSER privilege to ${APP_DB_USER}" \
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE \"${APP_DB_USER}\" WITH SUPERUSER;"

###############################################################################
# Grant privileges on database
###############################################################################

run "Granting database privileges to ${APP_DB_USER}" \
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d postgres \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"${APP_DB_NAME}\" TO \"${APP_DB_USER}\";"

###############################################################################
# Restore backup
###############################################################################

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

log "Restoring database backup"

run "Restoring database backup" \
    "${PG_RESTORE}" \
        -p "${POSTGRES_PORT}" \
        --username postgres \
        --dbname "${APP_DB_NAME}" \
        "${BACKUP_FILE}" \
        >/dev/null 2>&1 || true

###############################################################################
# Migration verification
###############################################################################

log "Querying migrations table for verification..."

RESULT=$(
    "${PSQL}" \
        -h 127.0.0.1 \
        -p 5431 \
        -U postgres \
        -d "${APP_DB_NAME}" \
        -At \
        -c "SELECT * FROM migrations;"
)

log "Migrations table output: ${RESULT}"

###############################################################################
# Application directory
###############################################################################

log "Creating application portal directory"

mkdir -p "${APP_DIR}"
chmod 0755 "${APP_DIR}"
chown -R root:apache "${APP_DIR}"

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

clone_or_update_repo() {

    local repo="$1"
    local branch="$2"
    local dest="$3"

    if [[ -d "${dest}/.git" ]]; then

        run "Updating repository metadata" git -C "${dest}" fetch --all --prune --quiet

        run "Checking out ${branch}" git -C "${dest}" checkout -q "${branch}"

        run "Synchronizing repository" git -C "${dest}" reset --hard "origin/${branch}"

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
    chown -R root:apache "${DEST}"

done

###############################################################################
# Application sessions directory
###############################################################################

SESSION_DIR="/var/www/${PORTAL_URL}/api/application/sessions"

log "Creating application session directory"

mkdir -p "${SESSION_DIR}"
chmod 0755 "${SESSION_DIR}"
chown -R root:apache "${SESSION_DIR}"

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

rendered = rendered.rstrip("\n") + "\n"

with open("${SITE_CONFIG}", "w") as f:
    f.write(rendered)
EOF

chmod 0644 "${SITE_CONFIG}"
chown root:root "${SITE_CONFIG}"

###############################################################################
# Apache log directory
###############################################################################

run "Creating Apache log directory" mkdir -p "/var/log/httpd/${PORTAL_URL}"
run "Setting Apache log directory ownership" chown root:root "/var/log/httpd/${PORTAL_URL}"
run "Setting Apache log directory permissions" chmod 0755 "/var/log/httpd/${PORTAL_URL}"

###############################################################################
# Validate Apache
###############################################################################

run "Validating Apache configuration" apachectl configtest

###############################################################################
# Restart Apache
###############################################################################

run "Restarting HTTPD service" systemctl restart httpd
run "Enabling HTTPD service" systemctl enable httpd

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

run "Installing TLS certificate" cp -f "${CERT_PATH}" "${CERT_DEST}"

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
run "Enabling HAProxy" systemctl enable --now haproxy

###############################################################################
# Update /etc/hosts entry
###############################################################################

SYSTEM_IP="$(hostname -I | awk '{print $1}')"

log "Adding Portal host entry to /etc/hosts"

grep -qE "^[[:space:]]*${SYSTEM_IP}[[:space:]]+${PORTAL_URL}$" /etc/hosts || \
    echo "${SYSTEM_IP} ${PORTAL_URL}" >> /etc/hosts

###############################################################################
# Application permissions
###############################################################################

run "Setting application permissions" \
    find "${APP_DIR}" -type d -exec chmod 0755 {} + && \
    find "${APP_DIR}" -type f -exec chmod 0644 {} +

run "Setting application ownership" chown -R root:apache "${APP_DIR}"

###############################################################################
# Configure SELinux file contexts
###############################################################################

run "Configuring SELinux context for sessions directory" \
    semanage fcontext -a -t httpd_sys_rw_content_t "${SESSIONS_DIR}(/.*)?"

run "Configuring SELinux context for media directory" \
    semanage fcontext -a -t httpd_sys_rw_content_t "${MEDIA_DIR}(/.*)?"

###############################################################################
# Apply SELinux contexts
###############################################################################

run "Restoring SELinux contexts for ${APP_DIR}" restorecon -RvF "${APP_DIR}"

###############################################################################
# Configure filesystem permissions
###############################################################################

run "Setting media directory permissions" chmod 770 "${MEDIA_DIR}"

run "Setting sessions directory permissions" chmod 770 "${SESSIONS_DIR}"

###############################################################################
# Completion
###############################################################################

unset PGPASSWORD
unset GIT_SSH_COMMAND
unset PORTAL_URL
unset ALLOWED_IPS
log "New portal configuration completed successfully."
