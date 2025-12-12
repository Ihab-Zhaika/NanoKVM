#!/bin/sh
# NanoKVM Installation Script
# Run this script via SSH on your NanoKVM device to install/update kvmapp files
#
# Usage:
#   1. Copy your kvmapp tarball to the NanoKVM device:
#      scp nanokvm-kvmapp-update.tar.gz root@<nanokvm-ip>:/tmp/
#
#   2. SSH into the device and run this script:
#      ssh root@<nanokvm-ip>
#      /kvmapp/system/install-kvmapp.sh /tmp/nanokvm-kvmapp-update.tar.gz
#
#   Or run directly from this script's location if it exists:
#      ./install-kvmapp.sh /tmp/nanokvm-kvmapp-update.tar.gz
#
# The script will:
#   - Stop running NanoKVM services
#   - Back up the current installation
#   - Extract and install new files
#   - Set correct permissions
#   - Restart services

set -e

# Configuration
KVMAPP_DIR="/kvmapp"
BACKUP_DIR="/root/kvmapp-backup"
SERVICE_SCRIPT="/etc/init.d/S95nanokvm"
MAX_BACKUPS=3

# Colors (may not work on all terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Display usage
usage() {
    cat << EOF
NanoKVM Installation Script

Usage: $0 <tarball_path>

Arguments:
  tarball_path    Path to the kvmapp update tarball (e.g., /tmp/nanokvm-kvmapp-update.tar.gz)

Options:
  --help, -h      Show this help message
  --rollback      Restore from the most recent backup

Examples:
  $0 /tmp/nanokvm-kvmapp-update.tar.gz
  $0 --rollback

Steps to update your NanoKVM:
  1. Build or download the kvmapp tarball
  2. Copy it to your NanoKVM: scp <tarball> root@<ip>:/tmp/
  3. SSH into the device: ssh root@<ip>
  4. Run: /kvmapp/system/install-kvmapp.sh /tmp/<tarball>

EOF
    exit 1
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Stop NanoKVM services
stop_services() {
    log_info "Stopping NanoKVM services..."
    
    if [ -x "$SERVICE_SCRIPT" ]; then
        "$SERVICE_SCRIPT" stop 2>/dev/null || true
    fi
    
    # Direct kill as fallback
    killall NanoKVM-Server 2>/dev/null || true
    killall kvm_system 2>/dev/null || true
    
    # Wait for processes to stop
    sleep 2
    
    # Verify and force kill if needed
    if pgrep -x "NanoKVM-Server" > /dev/null 2>&1; then
        log_warn "Force stopping NanoKVM-Server..."
        killall -9 NanoKVM-Server 2>/dev/null || true
    fi
    
    if pgrep -x "kvm_system" > /dev/null 2>&1; then
        log_warn "Force stopping kvm_system..."
        killall -9 kvm_system 2>/dev/null || true
    fi
    
    # Clean up temp directories
    rm -rf /tmp/kvm_system /tmp/server 2>/dev/null || true
    
    log_info "Services stopped"
}

# Start NanoKVM services
start_services() {
    log_info "Starting NanoKVM services..."
    
    if [ -x "$SERVICE_SCRIPT" ]; then
        "$SERVICE_SCRIPT" start
    else
        log_error "Service script not found: $SERVICE_SCRIPT"
        exit 1
    fi
    
    sleep 3
    log_info "Services started"
}

# Create backup of current installation
create_backup() {
    log_info "Creating backup..."
    
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_info "No existing installation found, skipping backup"
        return 0
    fi
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="${BACKUP_DIR}_${TIMESTAMP}"
    
    mkdir -p "$(dirname "$BACKUP_DIR")"
    cp -a "$KVMAPP_DIR" "$BACKUP_PATH"
    
    log_info "Backup created: $BACKUP_PATH"
    
    # Rotate old backups
    # shellcheck disable=SC2012
    BACKUP_COUNT=$(ls -1d "${BACKUP_DIR}_"* 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        log_info "Removing old backups..."
        # shellcheck disable=SC2012
        ls -1td "${BACKUP_DIR}_"* | tail -n +"$((MAX_BACKUPS + 1))" | xargs rm -rf
    fi
}

# Install kvmapp from tarball
install_kvmapp() {
    TARBALL="$1"
    
    log_info "Installing from: $TARBALL"
    
    # Verify tarball
    if [ ! -f "$TARBALL" ]; then
        log_error "Tarball not found: $TARBALL"
        exit 1
    fi
    
    # Verify it's a valid gzip file
    if ! gzip -t "$TARBALL" 2>/dev/null; then
        log_error "Invalid tarball (not a valid gzip file)"
        exit 1
    fi
    
    # Remove old kvmapp
    if [ -d "$KVMAPP_DIR" ]; then
        log_info "Removing old installation..."
        rm -rf "$KVMAPP_DIR"
    fi
    
    # Create kvmapp directory and extract
    log_info "Extracting files..."
    mkdir -p "$KVMAPP_DIR"
    tar -xzf "$TARBALL" -C "$KVMAPP_DIR"
    
    log_info "Files extracted successfully"
}

# Set correct permissions
set_permissions() {
    log_info "Setting permissions..."
    
    # Set directory permissions
    find "$KVMAPP_DIR" -type d -exec chmod 755 {} \;
    
    # Set file permissions
    find "$KVMAPP_DIR" -type f -exec chmod 644 {} \;
    
    # Make specific binaries executable
    [ -f "$KVMAPP_DIR/NanoKVM-Server" ] && chmod 755 "$KVMAPP_DIR/NanoKVM-Server"
    [ -f "$KVMAPP_DIR/server/NanoKVM-Server" ] && chmod 755 "$KVMAPP_DIR/server/NanoKVM-Server"
    [ -d "$KVMAPP_DIR/kvm_system" ] && chmod -R 755 "$KVMAPP_DIR/kvm_system"
    [ -f "$KVMAPP_DIR/kvm_new_app" ] && chmod 755 "$KVMAPP_DIR/kvm_new_app"
    
    # Make init scripts executable
    if [ -d "$KVMAPP_DIR/system/init.d" ]; then
        find "$KVMAPP_DIR/system/init.d" -maxdepth 1 -type f -exec chmod 755 {} \;
    fi
    
    # Make shell scripts executable
    find "$KVMAPP_DIR" -name "*.sh" -type f -exec chmod 755 {} \;
    
    log_info "Permissions set"
}

# Verify the installation
verify_installation() {
    log_info "Verifying installation..."
    
    WARNINGS=0
    
    # Check critical components
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_error "kvmapp directory not found!"
        return 1
    fi
    
    if [ -f "$KVMAPP_DIR/NanoKVM-Server" ] || [ -f "$KVMAPP_DIR/server/NanoKVM-Server" ]; then
        log_info "✓ NanoKVM-Server found"
    else
        log_warn "✗ NanoKVM-Server not found"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    if [ -d "$KVMAPP_DIR/kvm_system" ]; then
        log_info "✓ kvm_system directory found"
    else
        log_warn "✗ kvm_system directory not found"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    if [ -d "$KVMAPP_DIR/server/web" ]; then
        log_info "✓ Web frontend found"
    else
        log_warn "✗ Web frontend not found"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    # Check if services are running
    sleep 2
    if pgrep -x "NanoKVM-Server" > /dev/null 2>&1; then
        log_info "✓ NanoKVM-Server is running"
    else
        log_warn "✗ NanoKVM-Server is not running"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    if [ "$WARNINGS" -gt 0 ]; then
        log_warn "Installation completed with $WARNINGS warning(s)"
    else
        log_info "Installation verified successfully"
    fi
    
    return 0
}

# Rollback to previous backup
rollback() {
    log_info "Rolling back to previous backup..."
    
    # Find most recent backup
    # shellcheck disable=SC2012
    LATEST_BACKUP=$(ls -1td "${BACKUP_DIR}_"* 2>/dev/null | head -1)
    
    if [ -z "$LATEST_BACKUP" ] || [ ! -d "$LATEST_BACKUP" ]; then
        log_error "No backup found to restore"
        exit 1
    fi
    
    log_info "Restoring from: $LATEST_BACKUP"
    
    stop_services
    
    if [ -d "$KVMAPP_DIR" ]; then
        rm -rf "$KVMAPP_DIR"
    fi
    
    cp -a "$LATEST_BACKUP" "$KVMAPP_DIR"
    set_permissions
    start_services
    
    log_info "Rollback completed"
}

# List available backups
list_backups() {
    log_info "Available backups:"
    # shellcheck disable=SC2012
    BACKUP_LIST=$(ls -1td "${BACKUP_DIR}_"* 2>/dev/null)
    
    if [ -z "$BACKUP_LIST" ]; then
        log_info "  No backups found"
        return 0
    fi
    
    echo "$BACKUP_LIST" | while read -r backup; do
        size=$(du -sh "$backup" 2>/dev/null | cut -f1)
        printf "  %s (%s)\n" "$backup" "$size"
    done
}

# Main function
main() {
    # Handle help
    if [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ -z "$1" ]; then
        usage
    fi
    
    # Handle rollback
    if [ "$1" = "--rollback" ]; then
        check_root
        rollback
        exit 0
    fi
    
    # Handle list backups
    if [ "$1" = "--list-backups" ]; then
        list_backups
        exit 0
    fi
    
    TARBALL="$1"
    
    check_root
    
    log_info "========================================"
    log_info "NanoKVM Installation Script"
    log_info "========================================"
    log_info ""
    
    # Verify tarball exists
    if [ ! -f "$TARBALL" ]; then
        log_error "File not found: $TARBALL"
        log_info ""
        log_info "Make sure you've copied the tarball to the device first:"
        log_info "  scp nanokvm-kvmapp-update.tar.gz root@<ip>:/tmp/"
        exit 1
    fi
    
    stop_services
    create_backup
    install_kvmapp "$TARBALL"
    set_permissions
    start_services
    verify_installation
    
    log_info ""
    log_info "========================================"
    log_info "Installation completed!"
    log_info "========================================"
    log_info ""
    log_info "If you have issues, rollback with:"
    log_info "  $0 --rollback"
    log_info ""
}

main "$@"
