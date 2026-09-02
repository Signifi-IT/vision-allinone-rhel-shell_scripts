#!/bin/bash

###############################################################################
# Description:
#   Configures PostgreSQL application database and access on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Loads configuration from answers.txt
#     - Validates required variables
#     - Validates required files
#     - Temporarily sets local PostgreSQL authentication to trust before configuring the postgres password
#     - Sets PostgreSQL admin user (postgres) password
#     - Backs up pg_hba.conf
#     - Enforces SCRAM-SHA-256 authentication rules for local and network access and appending validated entries
#     - Restarts PostgreSQL after authentication changes
#     - Creates application database user with password
#     - Creates application database
#     - Grants required database privileges to application user
#     - Restores application database from backup
#     - Query migration table and logs results for verification
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
        error "Required variable '${var}' is not defined or is empty"
        exit 1
    fi
done

###############################################################################
# Validate required arrays
###############################################################################

if [[ "${#DB_USER_AUTHENTICATION_HBA[@]}" -eq 0 ]]; then
    error "Required array 'DB_USER_AUTHENTICATION_HBA' is not defined or is empty"
    exit 1
fi

if [[ "${#DB_NETWORK_AUTHENTICATION_HBA[@]}" -eq 0 ]]; then
    error "Required array 'DB_NETWORK_AUTHENTICATION_HBA' is not defined or is empty"
    exit 1
fi

###############################################################################
# Validate required files
###############################################################################

REQUIRED_FILES=(
    "${BACKUP_FILE}"
    "${PG_HBA}"
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
# Temporarily set PostgreSQL authentication to trust
###############################################################################

backup_file_if_needed "${PG_HBA}"

log "Temporarily setting PostgreSQL authentication to trust for password bootstrap"

TEMP_TRUST_CHANGED=0

if grep -qE '^[[:space:]]*local[[:space:]]+all[[:space:]]+all[[:space:]]+trust([[:space:]]|$)' "${PG_HBA}"; then

    log "Temporary local trust authentication is already configured"

else

    sed -i \
        "/^[[:space:]]*local[[:space:]]\+all[[:space:]]\+all[[:space:]]/d" \
        "${PG_HBA}"

    echo "local   all   all   trust" >> "${PG_HBA}"

    TEMP_TRUST_CHANGED=1

fi

if grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+postgres[[:space:]]+127\.0\.0\.1/32[[:space:]]+trust([[:space:]]|$)' "${PG_HBA}"; then

    log "Temporary TCP trust authentication for postgres is already configured"

else

    sed -i \
        "/^[[:space:]]*host[[:space:]]\+all[[:space:]]\+postgres[[:space:]]\+127\.0\.0\.1\/32[[:space:]]/d" \
        "${PG_HBA}"

    sed -i \
        "1ihost    all    postgres    127.0.0.1/32    trust" \
        "${PG_HBA}"

    TEMP_TRUST_CHANGED=1

fi

if [[ "${TEMP_TRUST_CHANGED}" -eq 1 ]]; then
    run "Restarting PostgreSQL to apply temporary trust authentication" systemctl restart postgresql-14
else
    log "Temporary trust authentication is already applied"
fi

run "Enabling PostgreSQL service" systemctl enable postgresql-14

log "Waiting for PostgreSQL readiness after temporary trust authentication..."

READY=0

for i in {1..30}; do
    if "${PG_ISREADY}" -h 127.0.0.1 -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
        READY=1
        log "PostgreSQL is ready after temporary trust authentication"
        break
    fi
    sleep 1
done

if [[ "${READY}" -ne 1 ]]; then
    error "PostgreSQL failed to become ready after temporary trust authentication"
    exit 1
fi

###############################################################################
# Set postgres admin password
###############################################################################

run "Setting postgres admin password" \
    "${PSQL}" \
        -h 127.0.0.1 \
        -d postgres \
        -U postgres \
        -p "${POSTGRES_PORT}" \
        -v ON_ERROR_STOP=1 \
        -c "ALTER USER postgres PASSWORD '${POSTGRES_ADMIN_PASSWORD}';"

###############################################################################
# Updating pg_hba.conf
###############################################################################

backup_file_if_needed "${PG_HBA}"

log "Configuring pg_hba.conf authentication rules..."

log "Removing temporary trust authentication rules"

sed -i \
    "/^[[:space:]]*local[[:space:]]\+all[[:space:]]\+all[[:space:]]\+trust[[:space:]]*$/d" \
    "${PG_HBA}"

sed -i \
    "/^[[:space:]]*host[[:space:]]\+all[[:space:]]\+postgres[[:space:]]\+127\.0\.0\.1\/32[[:space:]]\+trust[[:space:]]*$/d" \
    "${PG_HBA}"

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

export PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}"

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

    MIGRATION_COUNT=$(
        "${PSQL}" \
            -h 127.0.0.1 \
            -p "${POSTGRES_PORT}" \
            -U postgres \
            -d "${APP_DB_NAME}" \
            -At \
            -c "SELECT COUNT(*) FROM public.migrations;"
    )

    log "Migrations table exists. Migration records found: ${MIGRATION_COUNT}"

else

    warn "Migrations table does not exist in database ${APP_DB_NAME}. Migration verification skipped."

fi

###############################################################################
# Completion
###############################################################################

unset PGPASSWORD
log "PostgreSQL application setup completed successfully."
