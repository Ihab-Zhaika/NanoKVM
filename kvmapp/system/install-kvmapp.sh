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

# Configuration
KVMAPP_DIR="/kvmapp"
BACKUP_DIR="/root/kvmapp-backup"
SERVICE_SCRIPT="/etc/init.d/S95nanokvm"
VERSION_FILE="/kvmapp/version"
DEFAULT_LOG_FILE="/tmp/kvmapp-upgrade.log"
STATUS_FILE="/tmp/kvmapp-upgrade-status"
OLED_MESSAGE_FILE="/tmp/kvmapp-oled-message"
DOWNLOAD_DIR="/tmp"
MAX_BACKUPS=3

# Default package URL (set during build, leave empty for manual mode)
# This URL will be automatically configured when the script is part of a build artifact
DEFAULT_PACKAGE_URL=""

# Runtime options (can be overridden by command line)
LOG_FILE=""
ASYNC_MODE=0
PACKAGE_URL=""
LOCAL_PATH=""

# Colors (may not work on all terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize log file
init_log() {
    if [ -n "$LOG_FILE" ]; then
        # Create or truncate log file
        : > "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Upgrade log initialized" >> "$LOG_FILE"
    fi
}

# Logging functions - write to both stdout and log file if specified
log_info() {
    MSG="[INFO] $1"
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG_FILE"
    fi
    if [ "$ASYNC_MODE" -eq 0 ]; then
        printf "${GREEN}%s${NC}\n" "$MSG"
    fi
}

log_warn() {
    MSG="[WARN] $1"
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG_FILE"
    fi
    if [ "$ASYNC_MODE" -eq 0 ]; then
        printf "${YELLOW}%s${NC}\n" "$MSG"
    fi
}

log_error() {
    MSG="[ERROR] $1"
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG_FILE"
    fi
    if [ "$ASYNC_MODE" -eq 0 ]; then
        printf "${RED}%s${NC}\n" "$MSG"
    fi
}

# Write status to status file (for --get-status)
write_status() {
    STATUS="$1"
    PROGRESS="$2"
    echo "$STATUS" > "$STATUS_FILE"
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [STATUS] $STATUS (${PROGRESS}%)" >> "$LOG_FILE"
    fi
}

# Write message to OLED display file
# The kvm_system will read this and display on screen
write_oled_message() {
    MSG="$1"
    echo "$MSG" > "$OLED_MESSAGE_FILE"
}

# Clear OLED message file
clear_oled_message() {
    rm -f "$OLED_MESSAGE_FILE" 2>/dev/null
}

# Display usage
usage() {
    cat << EOF
NanoKVM Installation Script

Usage: $0 [OPTIONS] [tarball_path]

Arguments:
  tarball_path         Path to the kvmapp update tarball (e.g., /tmp/nanokvm-kvmapp-update.tar.gz)
                       Can be omitted if using --url to download

Options:
  --help, -h           Show this help message
  --rollback           Restore from the most recent backup
  --list-backups       List available backups
  --existing-version   Show the currently installed version
  --log-file <path>    Write upgrade log to specified file (default: $DEFAULT_LOG_FILE)
  --async              Run upgrade in background (async mode) - continues even if SSH disconnects
  --get-status         Check the status of an ongoing or completed upgrade
  --url <url>          Download package from URL (shows download progress)
  --local <path>       Use local file (same as providing path as argument)

Examples:
  # Download from URL and upgrade
  $0 --url https://example.com/nanokvm-kvmapp-update.tar.gz

  # Standard upgrade from local file
  $0 /tmp/nanokvm-kvmapp-update.tar.gz
  $0 --local /tmp/nanokvm-kvmapp-update.tar.gz

  # Async upgrade with URL download
  $0 --async --url https://example.com/nanokvm-kvmapp-update.tar.gz

  # Upgrade with logging
  $0 --log-file /tmp/upgrade.log /tmp/nanokvm-kvmapp-update.tar.gz

  # Async upgrade (runs in background, SSH-disconnect safe)
  $0 --async --log-file /tmp/upgrade.log /tmp/nanokvm-kvmapp-update.tar.gz

  # Check upgrade status
  $0 --get-status

  # Other commands
  $0 --rollback
  $0 --list-backups
  $0 --existing-version

Steps to update your NanoKVM:
  1. Build or download the kvmapp tarball
  2. Copy it to your NanoKVM: scp <tarball> root@<ip>:/tmp/
     Or use --url to download directly on the device
  3. SSH into the device: ssh root@<ip>
  4. Run: /kvmapp/system/install-kvmapp.sh /tmp/<tarball>
     Or: /kvmapp/system/install-kvmapp.sh --url <download_url>

EOF
    exit 1
}

# Get the currently installed version
get_existing_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '\n' < "$VERSION_FILE" 2>/dev/null
    else
        echo "unknown"
    fi
}

# Get version from tarball
get_tarball_version() {
    TARBALL="$1"
    if [ -f "$TARBALL" ]; then
        # Extract version file from tarball and read it
        VERSION=$(tar -xzf "$TARBALL" -O version 2>/dev/null | tr -d '\n')
        if [ -n "$VERSION" ]; then
            echo "$VERSION"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# Show existing version
show_existing_version() {
    VERSION=$(get_existing_version)
    echo "Currently installed version: $VERSION"
}

# Show upgrade status
show_status() {
    echo "=== Upgrade Status ==="
    
    # Check status file
    if [ -f "$STATUS_FILE" ]; then
        STATUS=$(cat "$STATUS_FILE")
        echo "Status: $STATUS"
    else
        echo "Status: No upgrade in progress or status not available"
    fi
    
    # Show log file if it exists
    if [ -f "$DEFAULT_LOG_FILE" ]; then
        echo ""
        echo "=== Recent Log Entries ==="
        tail -20 "$DEFAULT_LOG_FILE"
    elif [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo ""
        echo "=== Recent Log Entries ==="
        tail -20 "$LOG_FILE"
    fi
}

# Download package from URL with progress display
download_package() {
    URL="$1"
    OUTPUT_FILE="$2"
    
    log_info "Downloading package from: $URL"
    write_status "Downloading package" 5
    
    # Remove existing file if present
    rm -f "$OUTPUT_FILE" 2>/dev/null
    
    # Try wget first (preferred for progress display), then curl
    if command -v wget > /dev/null 2>&1; then
        log_info "Using wget for download..."
        if [ "$ASYNC_MODE" -eq 0 ]; then
            # Show progress bar in sync mode
            wget --progress=bar:force -O "$OUTPUT_FILE" "$URL" 2>&1
        else
            # No progress bar in async mode, just log
            wget -q -O "$OUTPUT_FILE" "$URL" 2>&1
        fi
        DOWNLOAD_STATUS=$?
    elif command -v curl > /dev/null 2>&1; then
        log_info "Using curl for download..."
        if [ "$ASYNC_MODE" -eq 0 ]; then
            # Show progress bar in sync mode
            curl -L --progress-bar -o "$OUTPUT_FILE" "$URL"
        else
            # Silent in async mode
            curl -sL -o "$OUTPUT_FILE" "$URL"
        fi
        DOWNLOAD_STATUS=$?
    else
        log_error "Neither wget nor curl is available for downloading"
        write_status "FAILED: No download tool available" 100
        exit 1
    fi
    
    if [ "$DOWNLOAD_STATUS" -ne 0 ]; then
        log_error "Download failed with status: $DOWNLOAD_STATUS"
        write_status "FAILED: Download failed" 100
        rm -f "$OUTPUT_FILE" 2>/dev/null
        exit 1
    fi
    
    # Verify the downloaded file exists and has content
    if [ ! -f "$OUTPUT_FILE" ] || [ ! -s "$OUTPUT_FILE" ]; then
        log_error "Download failed: File is empty or not created"
        write_status "FAILED: Download produced empty file" 100
        rm -f "$OUTPUT_FILE" 2>/dev/null
        exit 1
    fi
    
    # Get file size
    FILE_SIZE=$(du -h "$OUTPUT_FILE" 2>/dev/null | cut -f1)
    log_info "Download completed: $OUTPUT_FILE ($FILE_SIZE)"
    write_status "Download completed" 10
    
    echo "$OUTPUT_FILE"
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
    write_status "Stopping services" 10
    
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
    write_status "Services stopped" 20
}

# Start NanoKVM services
start_services() {
    log_info "Starting NanoKVM services..."
    write_status "Starting services" 80
    
    if [ -x "$SERVICE_SCRIPT" ]; then
        "$SERVICE_SCRIPT" start
    else
        log_error "Service script not found: $SERVICE_SCRIPT"
        write_status "FAILED: Service script not found" 100
        exit 1
    fi
    
    sleep 3
    log_info "Services started"
    write_status "Services started" 90
}

# Create backup of current installation
create_backup() {
    log_info "Creating backup..."
    write_status "Creating backup" 30
    
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_info "No existing installation found, skipping backup"
        return 0
    fi
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="${BACKUP_DIR}_${TIMESTAMP}"
    
    mkdir -p "$(dirname "$BACKUP_DIR")"
    cp -a "$KVMAPP_DIR" "$BACKUP_PATH"
    
    log_info "Backup created: $BACKUP_PATH"
    
    # Rotate old backups - count existing backups
    BACKUP_COUNT=0
    for dir in "${BACKUP_DIR}_"*; do
        [ -d "$dir" ] && BACKUP_COUNT=$((BACKUP_COUNT + 1))
    done
    
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        log_info "Removing old backups..."
        # shellcheck disable=SC2012
        # Using ls here because we need time-sorted listing and our backup names
        # are generated by this script with safe timestamp format (YYYYMMDD_HHMMSS)
        ls -1td "${BACKUP_DIR}_"* | tail -n +"$((MAX_BACKUPS + 1))" | while read -r old_backup; do
            rm -rf "$old_backup"
        done
    fi
    write_status "Backup complete" 40
}

# Install kvmapp from tarball
install_kvmapp() {
    TARBALL="$1"
    
    log_info "Installing from: $TARBALL"
    write_status "Installing files" 50
    
    # Verify tarball
    if [ ! -f "$TARBALL" ]; then
        log_error "Tarball not found: $TARBALL"
        write_status "FAILED: Tarball not found" 100
        exit 1
    fi
    
    # Verify it's a valid tarball (tar.gz)
    if ! tar -tzf "$TARBALL" > /dev/null 2>&1; then
        log_error "Invalid tarball (not a valid tar.gz file)"
        write_status "FAILED: Invalid tarball" 100
        exit 1
    fi
    
    # Remove old kvmapp
    if [ -d "$KVMAPP_DIR" ]; then
        log_info "Removing old installation..."
        rm -rf "$KVMAPP_DIR"
    fi
    
    # Create kvmapp directory and extract
    log_info "Extracting files..."
    write_status "Extracting files" 60
    mkdir -p "$KVMAPP_DIR"
    tar -xzf "$TARBALL" -C "$KVMAPP_DIR"
    
    log_info "Files extracted successfully"
    write_status "Files extracted" 70
}

# Set correct permissions
set_permissions() {
    log_info "Setting permissions..."
    write_status "Setting permissions" 75
    
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
    write_status "Verifying installation" 95
    
    WARNINGS=0
    
    # Check critical components
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_error "kvmapp directory not found!"
        write_status "FAILED: kvmapp directory not found" 100
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
    write_status "Rolling back" 10
    
    # Find most recent backup
    # shellcheck disable=SC2012
    LATEST_BACKUP=$(ls -1td "${BACKUP_DIR}_"* 2>/dev/null | head -1)
    
    if [ -z "$LATEST_BACKUP" ] || [ ! -d "$LATEST_BACKUP" ]; then
        log_error "No backup found to restore"
        write_status "FAILED: No backup found" 100
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
    write_status "Rollback completed" 100
}

# List available backups
list_backups() {
    echo "Available backups:"
    # shellcheck disable=SC2012
    BACKUP_LIST=$(ls -1td "${BACKUP_DIR}_"* 2>/dev/null)
    
    if [ -z "$BACKUP_LIST" ]; then
        echo "  No backups found"
        return 0
    fi
    
    echo "$BACKUP_LIST" | while read -r backup; do
        size=$(du -sh "$backup" 2>/dev/null | cut -f1)
        printf "  %s (%s)\n" "$backup" "$size"
    done
}

# Run the actual upgrade process
do_upgrade() {
    TARBALL="$1"
    
    # Remove set -e for the upgrade process to handle errors gracefully
    set +e
    
    init_log
    write_status "Starting upgrade" 0
    
    log_info "========================================"
    log_info "NanoKVM Installation Script"
    log_info "========================================"
    log_info ""
    
    # Get versions and display update message
    EXISTING_VERSION=$(get_existing_version)
    NEW_VERSION=$(get_tarball_version "$TARBALL")
    log_info "Updating from version: $EXISTING_VERSION"
    log_info "Updating to version:   $NEW_VERSION"
    log_info ""
    write_status "Upgrading from $EXISTING_VERSION to $NEW_VERSION" 5
    
    stop_services
    create_backup
    install_kvmapp "$TARBALL"
    set_permissions
    start_services
    verify_installation
    
    log_info ""
    log_info "========================================"
    log_info "Installation completed!"
    log_info "Updated from $EXISTING_VERSION to $NEW_VERSION"
    log_info "========================================"
    log_info ""
    log_info "If you have issues, rollback with:"
    log_info "  $0 --rollback"
    log_info ""
    
    write_status "SUCCESS: Updated from $EXISTING_VERSION to $NEW_VERSION" 100
    clear_oled_message
}

# Main function
main() {
    # Parse command line arguments
    TARBALL=""
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --rollback)
                check_root
                LOG_FILE="$DEFAULT_LOG_FILE"
                rollback
                exit 0
                ;;
            --list-backups)
                list_backups
                exit 0
                ;;
            --existing-version)
                show_existing_version
                exit 0
                ;;
            --get-status)
                show_status
                exit 0
                ;;
            --log-file)
                shift
                if [ -z "$1" ]; then
                    echo "Error: --log-file requires a path argument"
                    exit 1
                fi
                LOG_FILE="$1"
                shift
                ;;
            --async)
                ASYNC_MODE=1
                shift
                ;;
            --url)
                shift
                if [ -z "$1" ]; then
                    echo "Error: --url requires a URL argument"
                    exit 1
                fi
                PACKAGE_URL="$1"
                shift
                ;;
            --local)
                shift
                if [ -z "$1" ]; then
                    echo "Error: --local requires a path argument"
                    exit 1
                fi
                LOCAL_PATH="$1"
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                ;;
            *)
                # Positional argument - treat as local path for backward compatibility
                TARBALL="$1"
                shift
                ;;
        esac
    done
    
    # Determine the tarball source
    if [ -n "$PACKAGE_URL" ]; then
        # Download from URL specified via --url
        TARBALL="${DOWNLOAD_DIR}/nanokvm-kvmapp-update-$(date +%Y%m%d%H%M%S).tar.gz"
    elif [ -n "$LOCAL_PATH" ]; then
        TARBALL="$LOCAL_PATH"
    elif [ -z "$TARBALL" ] && [ -n "$DEFAULT_PACKAGE_URL" ]; then
        # Use default URL if no tarball specified and default URL is configured
        PACKAGE_URL="$DEFAULT_PACKAGE_URL"
        TARBALL="${DOWNLOAD_DIR}/nanokvm-kvmapp-update-$(date +%Y%m%d%H%M%S).tar.gz"
        echo "Using pre-configured download URL..."
    fi
    
    # If no tarball specified and no default URL, show usage
    if [ -z "$TARBALL" ] && [ -z "$PACKAGE_URL" ]; then
        usage
    fi
    
    # Set default log file if async mode and no log file specified
    if [ "$ASYNC_MODE" -eq 1 ] && [ -z "$LOG_FILE" ]; then
        LOG_FILE="$DEFAULT_LOG_FILE"
    fi
    
    check_root
    
    # Download package if URL provided
    if [ -n "$PACKAGE_URL" ]; then
        init_log
        TARBALL=$(download_package "$PACKAGE_URL" "$TARBALL")
    fi
    
    # Verify tarball exists
    if [ ! -f "$TARBALL" ]; then
        echo "Error: File not found: $TARBALL"
        echo ""
        echo "Make sure you've copied the tarball to the device first:"
        echo "  scp nanokvm-kvmapp-update.tar.gz root@<ip>:/tmp/"
        echo ""
        echo "Or use --url to download directly:"
        echo "  $0 --url <download_url>"
        exit 1
    fi
    
    if [ "$ASYNC_MODE" -eq 1 ]; then
        # Run in background with nohup to survive SSH disconnect
        echo "Starting upgrade in background (async mode)..."
        echo "Log file: $LOG_FILE"
        echo ""
        echo "Monitor progress with:"
        echo "  $0 --get-status"
        echo "  tail -f $LOG_FILE"
        echo ""
        
        # Build the command for async execution
        ASYNC_CMD="LOG_FILE='$LOG_FILE' ASYNC_MODE=1"
        if [ -n "$PACKAGE_URL" ]; then
            ASYNC_CMD="$ASYNC_CMD PACKAGE_URL='$PACKAGE_URL'"
        fi
        ASYNC_CMD="$ASYNC_CMD '$0' '$TARBALL'"
        
        # Use nohup and redirect all output to log file
        nohup sh -c "$ASYNC_CMD" > /dev/null 2>&1 &
        
        echo "Upgrade started in background (PID: $!)"
        exit 0
    else
        # Run synchronously
        do_upgrade "$TARBALL"
    fi
}

# Check if we're being called as a child process for async mode
if [ -n "$LOG_FILE" ] && [ "$ASYNC_MODE" = "1" ]; then
    # We're the async child process
    # Check if we need to download first
    if [ -n "$PACKAGE_URL" ]; then
        TARBALL="${DOWNLOAD_DIR}/nanokvm-kvmapp-update-$(date +%Y%m%d%H%M%S).tar.gz"
        init_log
        TARBALL=$(download_package "$PACKAGE_URL" "$TARBALL")
    else
        TARBALL="$1"
    fi
    do_upgrade "$TARBALL"
else
    # Normal entry point
    main "$@"
fi
