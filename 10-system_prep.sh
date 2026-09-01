#!/bin/bash

###############################################################################
# Description:
#   Performs system maintenance and configuration on RHEL-based systems:
#     - Requires root privileges
#     - Logs all actions to /var/log/vision_deployment.log
#     - Cleans and rebuilds the DNF package metadata cache
#     - Installs required system utilities and dependencies
#     - Performs a full system upgrade
#     - Removes unused packages
#     - Configures Vim as the default system editor
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
# Refresh DNF Metadata
###############################################################################

run "Cleaning DNF cache" dnf clean all
run "Rebuilding DNF package metadata cache" dnf makecache -y

###############################################################################
# DNF operations
###############################################################################

REQUIRED_PACKAGES=(
    bash-completion
    ca-certificates
    curl
    dnf-plugins-core
    git
    gnupg2
    libselinux
    mlocate
    policycoreutils
    policycoreutils-python-utils
    policycoreutils-restorecond
    python3-dnf
    python3-libselinux
    setroubleshoot
    setroubleshoot-plugins
    setroubleshoot-server
    traceroute
    vim
    vim-common
    vim-enhanced
    vim-filesystem
    vim-minimal
    wget
    yum-utils
)

run "Installing required packages" dnf install -y --refresh "${REQUIRED_PACKAGES[@]}"

run "Upgrading system packages" dnf upgrade -y --refresh

run "Removing unused packages" dnf autoremove -y

###############################################################################
# Editor configuration
###############################################################################

log "Configuring system-wide editor settings"

cat > /etc/profile.d/editor.sh <<'EOF'
export EDITOR=vim
export VISUAL=vim
EOF

chmod 0644 /etc/profile.d/editor.sh
chown root:root /etc/profile.d/editor.sh

###############################################################################
# Reboot
###############################################################################

warn "System reboot scheduled in 1 minute (60 seconds)..."
shutdown -r +1 "Rebooting to apply updates..."

###############################################################################
# Completion
###############################################################################

log "Configuration completed. Reboot pending."
