#!/bin/bash

###############################################################################
# Description:
#   Configures PostgreSQL application database and access on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt and validates required variables
#     - Waits for PostgreSQL service readiness
#     - Sets PostgreSQL administrator password
#     - Backs up pg_hba.conf before modification
#     - Enforces SCRAM-SHA-256 authentication rules for local and network access
#       by removing duplicates and appending validated entries
#     - Restarts PostgreSQL after authentication changes
#     - Creates application database user credentials
#     - Creates application database
#     - Grants required database privileges to application user
#     - Restores application database from backup
#     - Executes migration table query and logs results for verification
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

if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

log "Loading configuration from $CONFIG_FILE..."

if ! source "$CONFIG_FILE"; then
    error "Failed to load config file"
    exit 1
fi

###############################################################################
# Constants
###############################################################################

POSTGRES_PORT="5431"

PSQL="/usr/pgsql-14/bin/psql"
PG_ISREADY="/usr/pgsql-14/bin/pg_isready"
PG_RESTORE="/usr/pgsql-14/bin/pg_restore"

PG_HBA="/var/lib/pgsql/14/data/pg_hba.conf"

BACKUP_FILE="${BACKUP_FILE_PATH}"

###############################################################################
# Validate required variables
###############################################################################

REQUIRED_VARS=(
    POSTGRES_ADMIN_PASSWORD
    APP_DB_USER
    APP_DB_PASSWORD
    APP_DB_NAME
    BACKUP_FILE_PATH
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable '${var}' is not defined"
        exit 1
    fi
done

###############################################################################
# Validate backup file exists
###############################################################################

if [[ ! -f "${BACKUP_FILE}" ]]; then
    error "Backup file does not exist: ${BACKUP_FILE}"
    exit 1
fi

log "Backup file verified: ${BACKUP_FILE}"

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
# Set postgres admin password
###############################################################################

run "Setting postgres admin password" \
    sudo -u postgres "${PSQL}" -p "${POSTGRES_PORT}" -d postgres \
    -c "ALTER USER postgres PASSWORD '${POSTGRES_ADMIN_PASSWORD}';"

###############################################################################
# Updating pg_hba.conf
###############################################################################

backup_file_if_needed "${PG_HBA}"

log "Configuring pg_hba.conf authentication rules..."

for user in "${DB_USER_AUTHENTICATION_HBA[@]}"; do

    log "Configuring local authentication for user '${user}'"

    sed -i \
        "/^[[:space:]]*local[[:space:]]\+all[[:space:]]\+${user}[[:space:]]/d" \
        "${PG_HBA}"

    echo "local   all   ${user}   scram-sha-256" >> "${PG_HBA}"

done

for network in "${DB_NETWORK_AUTHENTICATION_HBA[@]}"; do

    log "Configuring network authentication for network '${network}'"

    escaped_network=$(printf '%s\n' "${network}" | sed 's/[.[\*^$()+?{|]/\\&/g')

    sed -i \
        "\|^[[:space:]]*host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+${escaped_network}[[:space:]]|d" \
        "${PG_HBA}"

    echo "host    all    all    ${network}    scram-sha-256" >> "${PG_HBA}"

done

run "Restarting PostgreSQL to apply pg_hba.conf changes" systemctl restart postgresql-14

run "Enabling PostgreSQL service" systemctl enable postgresql-14

log "Waiting for PostgreSQL readiness after restart..."

READY=0

for i in {1..30}; do
    if "${PG_ISREADY}" -h 127.0.0.1 -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
    READY=1
    log "PostgreSQL is ready after restart"
    break
    fi
    sleep 1
done

if [[ "${READY}" -ne 1 ]]; then
    error "PostgreSQL failed to become ready after restart"
    exit 1
fi

###############################################################################
# Create application database user
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
# Create application database
###############################################################################

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

    run "Creating application database" \
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
# Grant privileges on database
###############################################################################

run "Granting database privileges" \
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
    PGPASSWORD="${APP_DB_PASSWORD}" \
    "${PSQL}" \
        -h 127.0.0.1 \
        -p 5431 \
        -U "${APP_DB_USER}" \
        -d "${APP_DB_NAME}" \
        -At \
        -c "SELECT * FROM migrations;"
)

log "Migrations table output: ${RESULT}"

###############################################################################
# Completion
###############################################################################

unset PGPASSWORD
log "PostgreSQL application setup completed successfully."
