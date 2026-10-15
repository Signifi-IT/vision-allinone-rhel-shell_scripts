#!/bin/bash

###############################################################################
# Description:
#   Installs and configures the SeasLog PHP extension on RHEL-based systems:
#     - Requires root privileges
#     - Logs all operations to /var/log/vision_deployment.log
#     - Installs missing build dependencies required for PECL extension builds
#     - Creates the SeasLog source build directory
#     - Detects the latest stable SeasLog version from PECL
#     - Downloads the latest stable SeasLog source archive when missing
#     - Extracts the SeasLog source archive when missing
#     - Builds and installs the SeasLog PHP extension when seaslog.so is missing
#     - Creates or updates the SeasLog PHP INI configuration
#     - Creates required SeasLog log directories with apache ownership
#     - Configures SELinux file context rules for SeasLog log directories
#     - Applies SELinux contexts recursively using restorecon
#     - Adds the SeasLog PHP module to fapolicyd trust and updates the trust database
#     - Validates PHP module loading
#     - Restarts and enables PHP-FPM service
#     - Removes temporary SeasLog source archive and package metadata files
#     - Cleans up temporary PHP INI files on exit
#     - Retains the selected PECL version for recovery from interrupted runs
###############################################################################

set -Eeuo pipefail
set -o errtrace

###############################################################################
# Logging
###############################################################################

LOG_FILE="/var/log/vision_deployment.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

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
# Cleanup temporary PHP INI file on exit
###############################################################################

TEMP_SEASLOG_INI=""

cleanup() {
    if [[ -n "${TEMP_SEASLOG_INI:-}" && -f "${TEMP_SEASLOG_INI}" ]]; then
        rm -f "${TEMP_SEASLOG_INI}"
    fi
}

trap cleanup EXIT

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

    log "${message}"

    local output rc

    if output=$("$@" 2>&1); then
        return 0
    else
        rc=$?
        echo "${output}" >&2
        return "${rc}"
    fi
}

###############################################################################
# Constants
###############################################################################

SEASLOG_VERSION_URL="https://pecl.php.net/rest/r/seaslog/stable.txt"
SEASLOG_SRC_BASE="/usr/local/src/seaslog"
SEASLOG_VERSION_FILE="${SEASLOG_SRC_BASE}/.selected-version"

SEASLOG_INI="/etc/php.d/50-seaslog.ini"
SEASLOG_MODULE="/usr/lib64/php/modules/seaslog.so"

SEASLOG_LOG_BASE="/var/log/php"
SEASLOG_LOG_DIR="${SEASLOG_LOG_BASE}/seaslog"
SEASLOG_DEFAULT_LOGGER_DIR="${SEASLOG_LOG_DIR}/default"

###############################################################################
# Refresh DNF Metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# Required packages
###############################################################################

REQUIRED_PACKAGES=(
    autoconf
    automake
    gcc
    gcc-c++
    libtool
    m4
    make
    php-devel
    php-pear
    pkgconf-pkg-config
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
    run "Installing missing SeasLog build dependencies" \
        dnf install -y --refresh "${MISSING_PACKAGES[@]}"
else
    log "All SeasLog build dependencies are already installed"
fi

###############################################################################
# Validate required commands
###############################################################################

REQUIRED_COMMANDS=(
    curl
    make
    php
    php-config
    phpize
    restorecon
    semanage
    systemctl
    tar
)

for command in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        error "Required command not found: ${command}"
        exit 1
    fi
done

###############################################################################
# Check whether SeasLog installation is required
###############################################################################

SEASLOG_INSTALL_REQUIRED=1

if [[ -f "${SEASLOG_MODULE}" ]] && \
   php -n -d "extension=${SEASLOG_MODULE}" \
       -r 'exit(extension_loaded("seaslog") ? 0 : 1);' >/dev/null 2>&1; then
    log "SeasLog PHP module is installed and loadable: ${SEASLOG_MODULE}"
    log "Skipping PECL version lookup, download, extraction, build, and installation"
    SEASLOG_INSTALL_REQUIRED=0
else
    warn "SeasLog PHP module is missing or cannot be loaded. Installation is required."
fi

if [[ "${SEASLOG_INSTALL_REQUIRED}" -eq 1 ]]; then

    ###############################################################################
    # Detect latest stable SeasLog version
    ###############################################################################

    # The selected version survives an interrupted run so a retry uses
    # the same source version even if PECL publishes a newer release.
    run "Creating SeasLog source directory" install -d -m 0755 "${SEASLOG_SRC_BASE}"

    if [[ -f "${SEASLOG_VERSION_FILE}" ]]; then
        SEASLOG_VERSION="$(<"${SEASLOG_VERSION_FILE}")"
        log "Reusing previously selected SeasLog version: ${SEASLOG_VERSION}"
    else
        log "Checking latest stable SeasLog version from PECL"
        SEASLOG_VERSION="$(curl -fsSL --retry 3 --connect-timeout 15 "${SEASLOG_VERSION_URL}" | tr -d '[:space:]')"
    fi

    if [[ ! "${SEASLOG_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Invalid selected stable SeasLog version: ${SEASLOG_VERSION}"
        exit 1
    fi

    if [[ ! -f "${SEASLOG_VERSION_FILE}" ]]; then
        SEASLOG_VERSION_TEMP="$(mktemp "${SEASLOG_SRC_BASE}/.selected-version.XXXXXX")"
        printf '%s\n' "${SEASLOG_VERSION}" > "${SEASLOG_VERSION_TEMP}"
        mv -f "${SEASLOG_VERSION_TEMP}" "${SEASLOG_VERSION_FILE}"
        chmod 0644 "${SEASLOG_VERSION_FILE}"
        chown root:root "${SEASLOG_VERSION_FILE}"
        log "Saved selected SeasLog version for interrupted-run recovery: ${SEASLOG_VERSION}"
    fi

    SEASLOG_ARCHIVE="SeasLog-${SEASLOG_VERSION}.tgz"
    SEASLOG_URL="https://pecl.php.net/get/${SEASLOG_ARCHIVE}"
    SEASLOG_SRC_DIR="${SEASLOG_SRC_BASE}/SeasLog-${SEASLOG_VERSION}"
    SEASLOG_ARCHIVE_PATH="${SEASLOG_SRC_BASE}/${SEASLOG_ARCHIVE}"

    log "Latest stable SeasLog version: ${SEASLOG_VERSION}"

    ###############################################################################
    # Source directory
    ###############################################################################

    log "SeasLog source directory ready: ${SEASLOG_SRC_BASE}"

    ###############################################################################
    # Download SeasLog source archive
    ###############################################################################

    if [[ -f "${SEASLOG_ARCHIVE_PATH}" ]]; then
        if tar -tzf "${SEASLOG_ARCHIVE_PATH}" >/dev/null 2>&1; then
            log "SeasLog source archive already exists and is valid: ${SEASLOG_ARCHIVE_PATH}"
        else
            warn "SeasLog source archive is invalid or incomplete: ${SEASLOG_ARCHIVE_PATH}"
            run "Removing invalid SeasLog source archive" rm -f "${SEASLOG_ARCHIVE_PATH}"
        fi
    fi

    if [[ ! -f "${SEASLOG_ARCHIVE_PATH}" ]]; then
        run "Downloading SeasLog ${SEASLOG_VERSION} source archive" \
            curl -fL -o "${SEASLOG_ARCHIVE_PATH}" "${SEASLOG_URL}"

        if ! tar -tzf "${SEASLOG_ARCHIVE_PATH}" >/dev/null 2>&1; then
            error "Downloaded SeasLog source archive failed validation: ${SEASLOG_ARCHIVE_PATH}"
            exit 1
        fi

        log "SeasLog source archive validated successfully"
    fi

    ###############################################################################
    # Extract SeasLog source archive
    ###############################################################################

    if [[ -d "${SEASLOG_SRC_DIR}" ]]; then
        if [[ -f "${SEASLOG_SRC_DIR}/config.m4" ]] && \
           find "${SEASLOG_SRC_DIR}" -type f -name '*.c' -print -quit | grep -q .; then
            log "SeasLog source directory already extracted: ${SEASLOG_SRC_DIR}"
        else
            warn "SeasLog source directory is incomplete: ${SEASLOG_SRC_DIR}"
            run "Removing incomplete SeasLog source directory" rm -rf "${SEASLOG_SRC_DIR}"
        fi
    fi

    if [[ ! -d "${SEASLOG_SRC_DIR}" ]]; then
        run "Extracting SeasLog ${SEASLOG_VERSION} source archive" \
            tar -xzf "${SEASLOG_ARCHIVE_PATH}" -C "${SEASLOG_SRC_BASE}"
    fi

    if [[ ! -f "${SEASLOG_SRC_DIR}/config.m4" ]] || \
       ! find "${SEASLOG_SRC_DIR}" -type f -name '*.c' -print -quit | grep -q .; then
        error "SeasLog source extraction verification failed: ${SEASLOG_SRC_DIR}"
        exit 1
    fi

    ###############################################################################
    # Recover from an interrupted SeasLog build
    ###############################################################################

    if [[ -f "${SEASLOG_SRC_DIR}/Makefile" ]]; then
        warn "Existing SeasLog build artifacts detected. Re-extracting clean sources."
        run "Removing previous SeasLog build directory" rm -rf "${SEASLOG_SRC_DIR}"
        run "Extracting clean SeasLog ${SEASLOG_VERSION} sources" \
            tar -xzf "${SEASLOG_ARCHIVE_PATH}" -C "${SEASLOG_SRC_BASE}"

        if [[ ! -f "${SEASLOG_SRC_DIR}/config.m4" ]] || \
           ! find "${SEASLOG_SRC_DIR}" -type f -name '*.c' -print -quit | grep -q .; then
            error "Clean SeasLog source extraction verification failed: ${SEASLOG_SRC_DIR}"
            exit 1
        fi
    fi

    ###############################################################################
    # Build and install SeasLog extension
    ###############################################################################

    run "Preparing SeasLog build with phpize" \
        bash -c "cd '${SEASLOG_SRC_DIR}' && phpize"

    run "Configuring SeasLog build" \
        bash -c "cd '${SEASLOG_SRC_DIR}' && ./configure --with-php-config=/usr/bin/php-config"

    run "Building SeasLog extension" \
        bash -c "cd '${SEASLOG_SRC_DIR}' && make -j\"$(nproc)\""

    run "Installing SeasLog extension" \
        bash -c "cd '${SEASLOG_SRC_DIR}' && make install"

else
    log "SeasLog installation steps skipped because the PHP module is already installed"
fi

###############################################################################
# Validate SeasLog module file
###############################################################################

if [[ ! -f "${SEASLOG_MODULE}" ]]; then
    error "SeasLog module was not installed: ${SEASLOG_MODULE}"
    exit 1
fi

run "Setting SeasLog module ownership" chown root:root "${SEASLOG_MODULE}"
run "Setting SeasLog module permissions" chmod 0755 "${SEASLOG_MODULE}"

###############################################################################
# Configure SeasLog PHP INI
###############################################################################

TEMP_SEASLOG_INI="$(mktemp)"

cat > "${TEMP_SEASLOG_INI}" <<'EOF_INI'
[SeasLog]
extension=seaslog.so
seaslog.appender=1
seaslog.default_basepath=/var/log/php/seaslog
seaslog.default_logger=default
seaslog.default_datetime_format=Y-m-d H:i:s
EOF_INI

if [[ -f "${SEASLOG_INI}" ]] && cmp -s "${TEMP_SEASLOG_INI}" "${SEASLOG_INI}"; then
    log "SeasLog PHP INI configuration already up to date: ${SEASLOG_INI}"
    rm -f "${TEMP_SEASLOG_INI}"
else
    log "Deploying SeasLog PHP INI configuration: ${SEASLOG_INI}"
    cp -f "${TEMP_SEASLOG_INI}" "${SEASLOG_INI}"
    rm -f "${TEMP_SEASLOG_INI}"
fi

run "Setting SeasLog PHP INI permissions" chmod 0644 "${SEASLOG_INI}"
run "Setting SeasLog PHP INI ownership" chown root:root "${SEASLOG_INI}"

###############################################################################
# Create SeasLog log directories
###############################################################################

run "Creating PHP log directory" \
    install -d -m 0750 -o apache -g apache "${SEASLOG_LOG_BASE}"

run "Creating SeasLog log directory" \
    install -d -m 0750 -o apache -g apache "${SEASLOG_LOG_DIR}"

run "Creating SeasLog default logger directory" \
    install -d -m 0750 -o apache -g apache "${SEASLOG_DEFAULT_LOGGER_DIR}"

###############################################################################
# Configure SELinux file contexts
###############################################################################

SEASLOG_FCONTEXT_RULE="${SEASLOG_LOG_DIR}(/.*)?"

SEASLOG_FCONTEXT_CURRENT="$(
    semanage fcontext -l -C | awk -v rule="${SEASLOG_FCONTEXT_RULE}" \
        '$1 == rule { print $NF; exit }'
)"

if [[ -z "${SEASLOG_FCONTEXT_CURRENT}" ]]; then
    run "Adding SELinux context for SeasLog log directory" \
        semanage fcontext -a -t httpd_log_t "${SEASLOG_FCONTEXT_RULE}"
elif [[ "${SEASLOG_FCONTEXT_CURRENT}" == *:httpd_log_t:* ]]; then
    log "SELinux context already configured for SeasLog log directory: httpd_log_t"
else
    run "Updating SELinux context for SeasLog log directory" \
        semanage fcontext -m -t httpd_log_t "${SEASLOG_FCONTEXT_RULE}"
fi

run "Restoring SELinux contexts for SeasLog log directory" \
    restorecon -Rv "${SEASLOG_LOG_DIR}"

###############################################################################
# Configure fapolicyd trust
###############################################################################

if rpm -q fapolicyd >/dev/null 2>&1; then

    log "fapolicyd package is installed"

    if systemctl is-active --quiet fapolicyd; then

        log "fapolicyd service is running"

        SEASLOG_TRUST_FILE="/etc/fapolicyd/trust.d/seaslog"

        if [[ -f "${SEASLOG_TRUST_FILE}" ]] && \
           awk -v module="${SEASLOG_MODULE}" '$1 == module { found=1; exit } END { exit !found }' "${SEASLOG_TRUST_FILE}"; then

            log "SeasLog module already exists in fapolicyd trust file: ${SEASLOG_TRUST_FILE}"
            run "Refreshing SeasLog module size and hash in fapolicyd trust" \
                fapolicyd-cli --file update "${SEASLOG_MODULE}" --trust-file seaslog

        else

            run "Adding SeasLog module to fapolicyd trust" \
                fapolicyd-cli --file add "${SEASLOG_MODULE}" --trust-file seaslog

        fi

        run "Updating fapolicyd trust database" \
            fapolicyd-cli --update

    else

        log "fapolicyd service is not running. Skipping SeasLog trust configuration."

    fi

else

    log "fapolicyd package is not installed. Skipping SeasLog trust configuration."

fi

###############################################################################
# Validate SeasLog PHP module loading
###############################################################################

log "Validating SeasLog PHP extension"

if ! php -m | grep -qi '^seaslog$'; then
    error "SeasLog extension is not listed in loaded PHP modules"
    exit 1
fi

if ! php --ri seaslog | grep -E 'SeasLog support|Version' >/dev/null; then
    error "SeasLog extension information could not be verified"
    exit 1
fi

if ! php -r 'exit(extension_loaded("seaslog") ? 0 : 1);' \
    >/dev/null 2>&1; then
    error "SeasLog extension failed extension_loaded() verification"
    exit 1
fi

log "SeasLog PHP extension validation completed successfully"

###############################################################################
# Validate PHP-FPM configuration
###############################################################################

run "Validating PHP-FPM configuration" php-fpm -t

###############################################################################
# Restart PHP-FPM
###############################################################################

run "Restarting PHP-FPM service" systemctl restart php-fpm
run "Enabling PHP-FPM service" systemctl enable php-fpm

###############################################################################
# Cleanup temporary source files
###############################################################################

if [[ -f "${SEASLOG_SRC_BASE}/package.xml" ]]; then
    run "Removing SeasLog package metadata" rm -f "${SEASLOG_SRC_BASE}/package.xml"
else
    log "SeasLog package metadata already absent: ${SEASLOG_SRC_BASE}/package.xml"
fi

if [[ "${SEASLOG_INSTALL_REQUIRED}" -eq 1 ]]; then
    if [[ -f "${SEASLOG_ARCHIVE_PATH}" ]]; then
        run "Removing SeasLog source archive" rm -f "${SEASLOG_ARCHIVE_PATH}"
    else
        log "SeasLog source archive already absent: ${SEASLOG_ARCHIVE_PATH}"
    fi
else
    log "Skipping source archive cleanup because no SeasLog download was needed"
fi

###############################################################################
# Clear selected version after successful installation and verification
###############################################################################

if [[ -f "${SEASLOG_VERSION_FILE}" ]]; then
    run "Removing completed SeasLog version selection" rm -f "${SEASLOG_VERSION_FILE}"
fi

###############################################################################
# Completion
###############################################################################

log "SeasLog setup completed successfully."
