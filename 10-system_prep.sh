#!/bin/bash

###############################################################################
# Description:
#   Performs system maintenance and configuration on RHEL-based systems:
#     - Requires root privileges
#     - Logs all actions to /var/log/vision_deployment.log
#     - Loads and validates configuration from answers.txt
#     - Validates the configured system timezone
#     - Cleans and rebuilds the DNF package metadata cache
#     - Installs required system utilities and dependencies
#     - Removes Vim editor packages
#     - Performs a full system upgrade
#     - Removes unused packages
#     - Configures Nano as the default system editor
#     - Sets the system timezone
#     - Schedules a system reboot in 1 minute to apply changes
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

if [[ -z "${LOCAL_TIMEZONE:-}" ]]; then
    error "LOCAL_TIMEZONE is not defined in $CONFIG_FILE"
    exit 1
fi

TIMEZONE="$LOCAL_TIMEZONE"
log "Configured timezone: $TIMEZONE"

###############################################################################
# Validate timezone
###############################################################################

if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    error "Invalid timezone: $TIMEZONE"
    exit 1
fi

###############################################################################
# Packages
###############################################################################

REQUIRED_PACKAGES=(
    bash-completion
    ca-certificates
    curl
    dnf-plugins-core
    gnupg2
    libselinux
    nano
    policycoreutils
    policycoreutils-python-utils
    policycoreutils-restorecond
    python3-libselinux
    python3-dnf
    traceroute
    wget
    yum-utils
)

REMOVE_PACKAGES=(
    vim
    vim-enhanced
    vim-common
    vim-minimal
    vim-filesystem
)

###############################################################################
# DNF operations
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

run "Installing required packages" dnf install -y "${REQUIRED_PACKAGES[@]}"

run "Removing vim editor packages" dnf remove -y "${REMOVE_PACKAGES[@]}" \
    || warn "Failed to remove one or more vim editor packages"

run "Upgrading system packages" dnf upgrade -y --refresh

run "Removing unused packages" dnf autoremove -y

###############################################################################
# Editor configuration
###############################################################################

log "Configuring system-wide editor settings"

cat > /etc/profile.d/editor.sh <<'EOF'
export EDITOR=nano
export VISUAL=nano
EOF

chmod 0644 /etc/profile.d/editor.sh
chown root:root /etc/profile.d/editor.sh

###############################################################################
# Timezone configuration
###############################################################################

CURRENT_TZ="$(timedatectl show --property=Timezone --value)"

if [[ "$CURRENT_TZ" != "$TIMEZONE" ]]; then
    run "Setting timezone to $TIMEZONE" timedatectl set-timezone "$TIMEZONE"
else
    log "Timezone already set to $TIMEZONE"
fi

###############################################################################
# Reboot
###############################################################################

warn "System reboot scheduled in 1 minute (60 seconds)..."
shutdown -r +1 "Rebooting to apply updates..."

###############################################################################
# Completion
###############################################################################

log "Configuration completed. Reboot pending."
