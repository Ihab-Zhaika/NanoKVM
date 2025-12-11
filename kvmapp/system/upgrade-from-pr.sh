#!/bin/sh
# NanoKVM PR Upgrade Script
# This script safely upgrades NanoKVM from PR build artifacts
# Usage: upgrade-from-pr.sh <artifact_url_or_path>
#
# The script can accept:
#   - A local path to the tarball (e.g., /tmp/nanokvm-kvmapp-update.tar.gz)
#   - A URL to download the tarball from (e.g., https://storage.example.com/nanokvm-kvmapp-update.tar.gz)
#
# The script will:
#   1. Stop the running NanoKVM services
#   2. Backup the current installation
#   3. Extract the new files
#   4. Set correct permissions
#   5. Restart the services
#   6. Verify the installation

set -e

# Configuration
KVMAPP_DIR="/kvmapp"
BACKUP_DIR="/root/kvmapp-backup"
TEMP_DIR="/tmp/kvmapp-upgrade"
SERVICE_SCRIPT="/etc/init.d/S95nanokvm"
MAX_BACKUPS=3

# Colors for output (may not work on all terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo "${RED}[ERROR]${NC} $1"
}

# Display usage information
usage() {
    echo "NanoKVM PR Upgrade Script"
    echo ""
    echo "Usage: $0 <artifact_url_or_path>"
    echo ""
    echo "Arguments:"
    echo "  artifact_url_or_path  Local path or URL to the kvmapp update tarball"
    echo ""
    echo "Examples:"
    echo "  $0 /tmp/nanokvm-kvmapp-update.tar.gz"
    echo "  $0 https://storage.example.com/branch/version/nanokvm-kvmapp-update.tar.gz"
    echo ""
    echo "Options:"
    echo "  --help, -h    Show this help message"
    echo "  --rollback    Rollback to the previous backup"
    echo ""
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
        "$SERVICE_SCRIPT" stop || true
    else
        # Fallback: kill processes directly
        killall kvm_system 2>/dev/null || true
        killall NanoKVM-Server 2>/dev/null || true
    fi
    
    # Wait for processes to stop
    sleep 2
    
    # Verify processes are stopped
    if pgrep -x "NanoKVM-Server" > /dev/null 2>&1; then
        log_warn "NanoKVM-Server still running, force killing..."
        pkill -9 -x "NanoKVM-Server" || true
    fi
    
    if pgrep -x "kvm_system" > /dev/null 2>&1; then
        log_warn "kvm_system still running, force killing..."
        pkill -9 -x "kvm_system" || true
    fi
    
    # Clean up temp directories used by services
    rm -rf /tmp/kvm_system /tmp/server 2>/dev/null || true
    
    log_info "Services stopped successfully"
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
    
    # Wait for services to start
    sleep 3
    
    log_info "Services started"
}

# Create backup of current installation
create_backup() {
    log_info "Creating backup of current installation..."
    
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_warn "No existing kvmapp directory found, skipping backup"
        return 0
    fi
    
    # Create backup directory if it doesn't exist
    mkdir -p "$(dirname "$BACKUP_DIR")"
    
    # Create timestamped backup
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="${BACKUP_DIR}_${TIMESTAMP}"
    
    log_info "Backing up to: $BACKUP_PATH"
    cp -a "$KVMAPP_DIR" "$BACKUP_PATH"
    
    # Manage backup rotation - keep only MAX_BACKUPS most recent
    # ls is appropriate here for time-sorted listing
    # shellcheck disable=SC2012
    BACKUP_COUNT=$(ls -1d "${BACKUP_DIR}_"* 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        log_info "Rotating old backups (keeping $MAX_BACKUPS most recent)..."
        # ls -t is needed for time-sorted listing
        # shellcheck disable=SC2012
        ls -1td "${BACKUP_DIR}_"* | tail -n +"$((MAX_BACKUPS + 1))" | xargs rm -rf
    fi
    
    log_info "Backup created successfully"
}

# Download artifact from URL
download_artifact() {
    URL="$1"
    OUTPUT="$2"
    
    log_info "Downloading artifact from: $URL"
    
    # Try wget first (more common on embedded systems), then curl
    if command -v wget > /dev/null 2>&1; then
        wget -q -O "$OUTPUT" "$URL"
    elif command -v curl > /dev/null 2>&1; then
        curl -fsSL -o "$OUTPUT" "$URL"
    else
        log_error "Neither wget nor curl is available"
        exit 1
    fi
    
    # Verify download
    if [ ! -f "$OUTPUT" ] || [ ! -s "$OUTPUT" ]; then
        log_error "Failed to download artifact"
        exit 1
    fi
    
    log_info "Download completed"
}

# Extract and install the new kvmapp
install_kvmapp() {
    TARBALL="$1"
    
    log_info "Installing new kvmapp from: $TARBALL"
    
    # Verify tarball exists
    if [ ! -f "$TARBALL" ]; then
        log_error "Tarball not found: $TARBALL"
        exit 1
    fi
    
    # Create temp extraction directory
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Extract tarball
    log_info "Extracting tarball..."
    tar -xzf "$TARBALL" -C "$TEMP_DIR"
    
    # Verify extraction
    if [ ! -d "$TEMP_DIR" ] || [ -z "$(ls -A "$TEMP_DIR")" ]; then
        log_error "Extraction failed or produced empty directory"
        exit 1
    fi
    
    # Remove old kvmapp directory
    if [ -d "$KVMAPP_DIR" ]; then
        log_info "Removing old kvmapp directory..."
        rm -rf "$KVMAPP_DIR"
    fi
    
    # Move new files into place
    log_info "Installing new files..."
    mkdir -p "$KVMAPP_DIR"
    cp -a "$TEMP_DIR"/* "$KVMAPP_DIR"/
    
    # Clean up temp directory
    rm -rf "$TEMP_DIR"
    
    log_info "Installation completed"
}

# Set correct permissions
set_permissions() {
    log_info "Setting permissions..."
    
    # Set directory permissions
    find "$KVMAPP_DIR" -type d -exec chmod 755 {} \;
    
    # Set file permissions
    find "$KVMAPP_DIR" -type f -exec chmod 644 {} \;
    
    # Make executables executable
    [ -f "$KVMAPP_DIR/NanoKVM-Server" ] && chmod 755 "$KVMAPP_DIR/NanoKVM-Server"
    [ -f "$KVMAPP_DIR/server/NanoKVM-Server" ] && chmod 755 "$KVMAPP_DIR/server/NanoKVM-Server"
    [ -d "$KVMAPP_DIR/kvm_system" ] && chmod -R 755 "$KVMAPP_DIR/kvm_system"
    [ -f "$KVMAPP_DIR/kvm_new_app" ] && chmod 755 "$KVMAPP_DIR/kvm_new_app"
    
    # Make init scripts executable
    if [ -d "$KVMAPP_DIR/system/init.d" ]; then
        chmod 755 "$KVMAPP_DIR/system/init.d"/*
    fi
    
    # Make shell scripts executable
    find "$KVMAPP_DIR" -name "*.sh" -type f -exec chmod 755 {} \;
    
    log_info "Permissions set successfully"
}

# Verify the installation
verify_installation() {
    log_info "Verifying installation..."
    
    ERRORS=0
    
    # Check kvmapp directory exists
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_error "kvmapp directory not found"
        ERRORS=$((ERRORS + 1))
    fi
    
    # Check for server binary (could be in root or server subdirectory)
    if [ -f "$KVMAPP_DIR/NanoKVM-Server" ]; then
        log_info "Found NanoKVM-Server in root"
    elif [ -f "$KVMAPP_DIR/server/NanoKVM-Server" ]; then
        log_info "Found NanoKVM-Server in server/"
    else
        log_warn "NanoKVM-Server binary not found (may be in a different location)"
    fi
    
    # Check for web frontend
    if [ -d "$KVMAPP_DIR/server/web" ]; then
        log_info "Found web frontend"
    else
        log_warn "Web frontend directory not found"
    fi
    
    # Verify services are running
    sleep 2
    if pgrep -x "NanoKVM-Server" > /dev/null 2>&1; then
        log_info "NanoKVM-Server is running"
    else
        log_warn "NanoKVM-Server is not running"
        ERRORS=$((ERRORS + 1))
    fi
    
    if [ "$ERRORS" -gt 0 ]; then
        log_warn "Verification completed with $ERRORS warning(s)"
    else
        log_info "Verification completed successfully"
    fi
    
    return 0
}

# Rollback to previous backup
rollback() {
    log_info "Rolling back to previous backup..."
    
    # Find the most recent backup
    # ls -t is needed for time-sorted listing
    # shellcheck disable=SC2012
    LATEST_BACKUP=$(ls -1td "${BACKUP_DIR}_"* 2>/dev/null | head -1)
    
    if [ -z "$LATEST_BACKUP" ] || [ ! -d "$LATEST_BACKUP" ]; then
        log_error "No backup found to rollback to"
        exit 1
    fi
    
    log_info "Found backup: $LATEST_BACKUP"
    
    # Stop services first
    stop_services
    
    # Remove current installation
    if [ -d "$KVMAPP_DIR" ]; then
        rm -rf "$KVMAPP_DIR"
    fi
    
    # Restore backup
    cp -a "$LATEST_BACKUP" "$KVMAPP_DIR"
    
    # Set permissions
    set_permissions
    
    # Start services
    start_services
    
    log_info "Rollback completed successfully"
}

# Main upgrade process
main() {
    # Check for help flag
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        usage
    fi
    
    # Check for rollback flag
    if [ "$1" = "--rollback" ]; then
        check_root
        rollback
        exit 0
    fi
    
    # Check arguments
    if [ $# -lt 1 ]; then
        log_error "Missing argument: artifact URL or path"
        usage
    fi
    
    ARTIFACT="$1"
    
    # Check root
    check_root
    
    log_info "========================================"
    log_info "NanoKVM PR Upgrade Script"
    log_info "========================================"
    log_info ""
    
    # Determine if artifact is URL or local path
    TARBALL=""
    if echo "$ARTIFACT" | grep -qE '^https?://'; then
        # It's a URL, download it
        TARBALL="/tmp/nanokvm-pr-update.tar.gz"
        download_artifact "$ARTIFACT" "$TARBALL"
    else
        # It's a local path
        TARBALL="$ARTIFACT"
        if [ ! -f "$TARBALL" ]; then
            log_error "File not found: $TARBALL"
            exit 1
        fi
    fi
    
    # Stop services
    stop_services
    
    # Create backup
    create_backup
    
    # Install new kvmapp
    install_kvmapp "$TARBALL"
    
    # Set permissions
    set_permissions
    
    # Start services
    start_services
    
    # Verify installation
    verify_installation
    
    # Cleanup downloaded file if we downloaded it
    if echo "$ARTIFACT" | grep -qE '^https?://'; then
        rm -f "$TARBALL"
    fi
    
    log_info ""
    log_info "========================================"
    log_info "Upgrade completed successfully!"
    log_info "========================================"
    log_info ""
    log_info "If you encounter issues, you can rollback using:"
    log_info "  $0 --rollback"
    log_info ""
}

# Run main function
main "$@"
