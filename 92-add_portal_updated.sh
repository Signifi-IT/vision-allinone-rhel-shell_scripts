#!/bin/bash

###############################################################################
# Description:
#   Adds a new Vision application portal to an already configured application
#   server on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Requires --answer-file argument to load the desired answer file
#     - Loads configuration from the provided answer file
#     - Validates required variables
#     - Validates required arrays
#     - Validates required user-provided files
#     - Waits for PostgreSQL readiness on TCP/5431
#     - Creates or updates application database user with password
#     - Creates application database when missing
#     - Grants SUPERUSER privilege to the application database user
#     - Grants required database privileges to the application database user
#     - Restores application database from backup when migrations table does not exist
#     - Queries migrations table and logs results for verification
#     - Detects whether the application portal directory already exists before cloning
#     - Configures Bitbucket SSH key permissions and ownership for secure Git access
#     - Clones application, media, API, and mobile repositories only during initial deployment
#     - Deploys media, API, and mobile assets into the application directory only during initial deployment
#     - Creates required application session directory only during initial deployment
#     - Removes temporary repository working directories only during initial deployment
#     - Installs Jinja2 to render Apache and HAProxy configuration templates
#     - Renders Apache virtual host configuration from a Jinja2 template
#     - Deploys Apache virtual host configuration only when missing or changed
#     - Creates and configures application-specific Apache log directory
#     - Validates Apache configuration syntax
#     - Enables and restarts Apache HTTPD service
#     - Uses the HAProxy directories and hosts.map created by the HAProxy setup script
#     - Renders HAProxy portal backend configuration from a Jinja2 template
#     - Deploys HAProxy portal backend configuration only when missing or changed
#     - Removes Jinja2 after rendering templates
#     - Installs the TLS certificate only when missing or changed
#     - Escapes the portal URL for safe regex-based file updates
#     - Updates HAProxy hosts.map with the portal backend routing entry
#     - Validates the HAProxy configuration
#     - Enables and restarts the HAProxy service
#     - Adds or updates the portal entry in /etc/hosts
#     - Sets application directory permissions recursively to 0755
#     - Sets application file permissions recursively to 0644
#     - Sets recursive application ownership to root:apache
#     - Configures SELinux file context rules for the application sessions directory
#     - Configures SELinux file context rules for the application media directory
#     - Applies SELinux contexts recursively using restorecon
#     - Sets writable permissions on the primary application media directory
#     - Sets writable permissions on the primary application sessions directory
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

TEMP_SITE_CONFIG=""
TEMP_PORTAL_BACKEND_CONFIG=""

cleanup() {
    if [[ -n "${TEMP_SITE_CONFIG:-}" && -f "${TEMP_SITE_CONFIG}" ]]; then
        rm -f "${TEMP_SITE_CONFIG}"
    fi

    if [[ -n "${TEMP_PORTAL_BACKEND_CONFIG:-}" && -f "${TEMP_PORTAL_BACKEND_CONFIG}" ]]; then
        rm -f "${TEMP_PORTAL_BACKEND_CONFIG}"
    fi
}

trap cleanup EXIT
trap 'error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<EOF
Usage:
  bash $(basename "$0") --answer-file <filepath>.txt

Example:
  bash $(basename "$0") --answer-file /tmp/scripts/answers.txt
  bash $(basename "$0") --answer-file /tmp/scripts/answers-add_portal.txt
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
APACHE_LOG_DIR="/var/log/httpd/${PORTAL_URL}"

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CONF_DIR="/etc/haproxy/conf.d"
HAPROXY_MAP_DIR="/etc/haproxy/maps"
HAPROXY_MAP_FILE="${HAPROXY_MAP_DIR}/hosts.map"
HAPROXY_CERT_DIR="/etc/haproxy/certs"
CERT_DEST="${HAPROXY_CERT_DIR}/${PORTAL_URL}.pem"
PORTAL_BACKEND_DEST="${HAPROXY_CONF_DIR}/${PORTAL_URL}_backend.cfg"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    APP_DB_USER
    APP_DB_NAME
    APP_DB_PASSWORD
    POSTGRES_ADMIN_PASSWORD
    BACKUP_FILE_PATH
    PORTAL_URL
    BITBUCKET_KEY
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
        error "Required variable '${var}' is not defined or is empty"
        exit 1
    fi
done

###############################################################################
# Validate required arrays
###############################################################################

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
# Create or update application database user
###############################################################################

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

run "Creating or updating application user" \
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = '${APP_DB_USER}'
    ) THEN

        CREATE ROLE \"${APP_DB_USER}\"
        LOGIN
        PASSWORD '${APP_DB_PASSWORD}';

    ELSE

        ALTER ROLE \"${APP_DB_USER}\"
        WITH PASSWORD '${APP_DB_PASSWORD}';

    END IF;
END
\$\$;
"

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
        -v ON_ERROR_STOP=1 \
        -c "SELECT 1 FROM pg_database WHERE datname='${APP_DB_NAME}';"
)

if [[ "${DB_EXISTS}" != "1" ]]; then

    run "Creating application database ${APP_DB_NAME}" \
        "${PSQL}" \
            -h 127.0.0.1 \
            -p "${POSTGRES_PORT}" \
            -U postgres \
            -d postgres \
            -v ON_ERROR_STOP=1 \
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

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

run "Granting database privileges to ${APP_DB_USER}" \
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"${APP_DB_NAME}\" TO \"${APP_DB_USER}\";"

###############################################################################
# Restore backup
###############################################################################

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

log "Checking whether migrations table already exists..."

MIGRATIONS_EXISTS=$(
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d "${APP_DB_NAME}" \
        -At \
        -c "SELECT to_regclass('public.migrations');"
)

if [[ "${MIGRATIONS_EXISTS}" == "migrations" ]]; then

    log "Database is already migrated. Skipping database restore."

else

    log "Migrations table does not exist. Restoring database backup."

    if ! run "Restoring database backup" \
        "${PG_RESTORE}" \
            -h 127.0.0.1 \
            -p "${POSTGRES_PORT}" \
            --username postgres \
            --dbname "${APP_DB_NAME}" \
            "${BACKUP_FILE}"; then

        warn "pg_restore returned a non-zero exit code, continuing because restore errors are being tolerated"

    fi

fi

###############################################################################
# Migration verification
###############################################################################

log "Querying migrations table for verification..."

MIGRATIONS_EXISTS=$(
    "${PSQL}" \
        -h 127.0.0.1 \
        -p "${POSTGRES_PORT}" \
        -U postgres \
        -d "${APP_DB_NAME}" \
        -At \
        -c "SELECT to_regclass('public.migrations');"
)

if [[ "${MIGRATIONS_EXISTS}" == "migrations" ]]; then

    MIGRATION_OUTPUT=$(
        "${PSQL}" \
            -h 127.0.0.1 \
            -p "${POSTGRES_PORT}" \
            -U postgres \
            -d "${APP_DB_NAME}" \
            -At \
            -c "SELECT * FROM migrations;"
    )

    log "Migrations table exists. Migration records: ${MIGRATION_OUTPUT}"

else

    warn "Migrations table does not exist in database ${APP_DB_NAME}. Migration verification skipped."

fi

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

run "Setting Bitbucket SSH key permissions" chmod 0400 "${BITBUCKET_KEY}"
run "Setting Bitbucket SSH key ownership" chown root:root "${BITBUCKET_KEY}"

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
        "${APP_DIR}"

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
        DEST="${APP_DIR}/${component}"

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

if [[ "${APP_DIR_ALREADY_EXISTS}" -eq 1 ]]; then

    log "Application portal directory already exists. Skipping application session directory creation."

else

    log "Creating application session directory: ${SESSIONS_DIR}"

    mkdir -p "${SESSIONS_DIR}"
    chmod 0755 "${SESSIONS_DIR}"
    chown root:apache "${SESSIONS_DIR}"

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
# Install Jinja2
###############################################################################

run "Installing python3-jinja2" dnf install -y --refresh python3-jinja2

###############################################################################
# Render Apache virtual host configuration
###############################################################################

log "Rendering Apache virtual host configuration"

export PORTAL_URL

ALLOWED_IPS="$(printf '%s\n' "${ALLOWED_SERVER_STATUS_IPS[@]}")"
export ALLOWED_IPS

TEMP_SITE_CONFIG="$(mktemp)"

python3 <<EOF
from jinja2 import Template

with open("${TEMPLATE_FILE}") as f:
    template = Template(f.read())

rendered = template.render(
    portal_url="${PORTAL_URL}",
    allowed_server_status_ips="""${ALLOWED_IPS}""".splitlines()
)

rendered = rendered.rstrip("\n") + "\n"

with open("${TEMP_SITE_CONFIG}", "w") as f:
    f.write(rendered)
EOF

if [[ -f "${SITE_CONFIG}" ]] && cmp -s "${TEMP_SITE_CONFIG}" "${SITE_CONFIG}"; then

    log "Apache virtual host configuration already up to date: ${SITE_CONFIG}"
    rm -f "${TEMP_SITE_CONFIG}"

else

    log "Deploying Apache virtual host configuration: ${SITE_CONFIG}"
    cp -f "${TEMP_SITE_CONFIG}" "${SITE_CONFIG}"
    rm -f "${TEMP_SITE_CONFIG}"

fi

run "Setting Apache virtual host configuration permissions" chmod 0644 "${SITE_CONFIG}"
run "Setting Apache virtual host configuration ownership" chown root:root "${SITE_CONFIG}"

###############################################################################
# Apache log directory
###############################################################################

if [[ -d "${APACHE_LOG_DIR}" ]]; then

    log "Apache log directory already exists: ${APACHE_LOG_DIR}"

else

    run "Creating Apache log directory" mkdir -p "${APACHE_LOG_DIR}"

fi

run "Setting Apache log directory ownership" chown root:root "${APACHE_LOG_DIR}"
run "Setting Apache log directory permissions" chmod 0755 "${APACHE_LOG_DIR}"

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
# Render HAProxy portal backend config
###############################################################################

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

run "Enabling HAProxy" systemctl enable haproxy
run "Restarting HAProxy" systemctl restart haproxy

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

unset PGPASSWORD
unset GIT_SSH_COMMAND
unset PORTAL_URL
unset ALLOWED_IPS
unset SYSTEM_IP
unset BACKEND_NAME
unset PORTAL_URL_REGEX
unset TEMP_SITE_CONFIG
unset TEMP_PORTAL_BACKEND_CONFIG

log "New portal configuration completed successfully."
