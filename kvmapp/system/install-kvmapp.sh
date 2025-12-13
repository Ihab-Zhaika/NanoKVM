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

# Configuration - matches native update.go paths
KVMAPP_DIR="/kvmapp"
BACKUP_DIR="/root/old"           # Same as native: BackupDir = "/root/old"
CACHE_DIR="/root/.kvmcache"      # Same as native: CacheDir = "/root/.kvmcache"
SERVICE_SCRIPT="/etc/init.d/S95nanokvm"
VERSION_FILE="/kvmapp/version"
DEFAULT_LOG_FILE="/tmp/kvmapp-upgrade.log"
STATUS_FILE="/tmp/kvmapp-upgrade-status"
OLED_MESSAGE_FILE="/tmp/kvmapp-oled-message"
DOWNLOAD_DIR="/tmp"

# Default package URL (set during build, leave empty for manual mode)
# This URL will be automatically configured when the script is part of a build artifact
DEFAULT_PACKAGE_URL=""

# Runtime options (can be overridden by command line)
LOG_FILE=""
ASYNC_MODE=0
PACKAGE_URL=""
LOCAL_PATH=""
SOURCE_DIR=""

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
                       Can be omitted if using --url to download or --dir for unpacked directory

Options:
  --help, -h           Show this help message
  --rollback           Restore from the most recent backup
  --list-backups       List available backups
  --existing-version   Show the currently installed version
  --log-file <path>    Write upgrade log to specified file (default: $DEFAULT_LOG_FILE)
  --async              Run upgrade in background (async mode) - continues even if SSH disconnects
  --get-status         Check the status of an ongoing or completed upgrade
  --url <url>          Download package from URL (shows download progress)
  --local <path>       Use local tarball file (same as providing path as argument)
  --dir <path>         Use unpacked directory instead of tarball (copies files directly)

Examples:
  # Download from URL and upgrade
  $0 --url https://example.com/nanokvm-kvmapp-update.tar.gz

  # Standard upgrade from local tarball
  $0 /tmp/nanokvm-kvmapp-update.tar.gz
  $0 --local /tmp/nanokvm-kvmapp-update.tar.gz

  # Upgrade from unpacked directory
  $0 --dir /tmp/kvmapp

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
  1. Build or download the kvmapp tarball (or extract it to a directory)
  2. Copy it to your NanoKVM: scp <tarball> root@<ip>:/tmp/
     Or use --url to download directly on the device
  3. SSH into the device: ssh root@<ip>
  4. Run: /kvmapp/system/install-kvmapp.sh /tmp/<tarball>
     Or: /kvmapp/system/install-kvmapp.sh --dir /tmp/kvmapp

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

# Get version from package (ZIP or tar.gz)
get_tarball_version() {
    PACKAGE="$1"
    if [ -f "$PACKAGE" ]; then
        # Check file type by magic bytes
        MAGIC_BYTES=$(head -c 4 "$PACKAGE" 2>/dev/null | od -A n -t x1 | tr -d ' \n')
        FIRST_TWO=$(echo "$MAGIC_BYTES" | cut -c1-4)
        
        if [ "$FIRST_TWO" = "504b" ]; then
            # ZIP file - extract version using unzip
            VERSION=$(unzip -p "$PACKAGE" version 2>/dev/null | tr -d '\n')
        else
            # tar.gz file
            VERSION=$(tar -xzf "$PACKAGE" -O version 2>/dev/null | tr -d '\n')
        fi
        
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
    
    # Prefer curl for HTTPS support (BusyBox wget may not support HTTPS)
    # curl is more reliable for HTTPS URLs
    if command -v curl > /dev/null 2>&1; then
        log_info "Using curl for download..."
        if [ "$ASYNC_MODE" -eq 0 ]; then
            # Show progress bar in sync mode
            curl -fL --progress-bar -o "$OUTPUT_FILE" "$URL"
        else
            # Silent in async mode
            curl -fsL -o "$OUTPUT_FILE" "$URL"
        fi
        DOWNLOAD_STATUS=$?
    elif command -v wget > /dev/null 2>&1; then
        log_info "Using wget for download..."
        # Use simple wget options compatible with BusyBox
        # BusyBox wget doesn't support --progress or HTTPS well
        if [ "$ASYNC_MODE" -eq 0 ]; then
            # Basic wget without progress (BusyBox compatible)
            wget -O "$OUTPUT_FILE" "$URL" 2>&1
        else
            # Quiet mode
            wget -q -O "$OUTPUT_FILE" "$URL" 2>&1
        fi
        DOWNLOAD_STATUS=$?
    else
        log_error "Neither curl nor wget is available for downloading"
        write_status "FAILED: No download tool available" 100
        exit 1
    fi
    
    if [ "$DOWNLOAD_STATUS" -ne 0 ]; then
        log_error "Download failed with status: $DOWNLOAD_STATUS"
        log_error "If using HTTPS URL, ensure curl is available (BusyBox wget may not support HTTPS)"
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
    
    # Check if downloaded file is an HTML error page (common issue with Azure SAS)
    FIRST_BYTES=$(head -c 20 "$OUTPUT_FILE" 2>/dev/null | cat -v)
    if echo "$FIRST_BYTES" | grep -qi "<?xml\|<html\|<!DOCTYPE"; then
        log_error "Download failed: Server returned an error page instead of the file"
        log_error "This may indicate an expired or invalid download URL"
        log_error "First bytes of response: $FIRST_BYTES"
        write_status "FAILED: Server error page received" 100
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

# Create backup of current installation (matches native update.go behavior)
create_backup() {
    log_info "Creating backup..."
    write_status "Creating backup" 30
    
    if [ ! -d "$KVMAPP_DIR" ]; then
        log_info "No existing installation found, skipping backup"
        return 0
    fi
    
    # Remove old backup (same as native: os.RemoveAll(BackupDir))
    if [ -d "$BACKUP_DIR" ]; then
        log_info "Removing old backup..."
        rm -rf "$BACKUP_DIR"
    fi
    
    # Move current installation to backup (same as native: MoveFilesRecursively(AppDir, BackupDir))
    # Using mv is faster than cp for large directories
    log_info "Moving current installation to backup..."
    mv "$KVMAPP_DIR" "$BACKUP_DIR"
    
    log_info "Backup created: $BACKUP_DIR"
    write_status "Backup complete" 40
}

# Install kvmapp from package (ZIP or tar.gz) - matches native update.go behavior
install_kvmapp() {
    PACKAGE="$1"
    
    log_info "Installing from: $PACKAGE"
    write_status "Installing files" 50
    
    # Verify package exists
    if [ ! -f "$PACKAGE" ]; then
        log_error "Package not found: $PACKAGE"
        write_status "FAILED: Package not found" 100
        exit 1
    fi
    
    # Get file info for debugging
    FILE_SIZE=$(ls -la "$PACKAGE" 2>/dev/null | awk '{print $5}')
    log_info "Package size: $FILE_SIZE bytes"
    
    # Check file type by magic bytes
    MAGIC_BYTES=$(head -c 4 "$PACKAGE" 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    log_info "File header (hex): $MAGIC_BYTES"
    
    # Detect file type: ZIP (504b0304) or gzip (1f8b)
    IS_ZIP=0
    IS_GZIP=0
    
    FIRST_TWO=$(echo "$MAGIC_BYTES" | cut -c1-4)
    if [ "$FIRST_TWO" = "504b" ]; then
        IS_ZIP=1
        log_info "Detected ZIP archive"
    elif [ "$FIRST_TWO" = "1f8b" ]; then
        IS_GZIP=1
        log_info "Detected gzip archive"
    else
        log_error "Unknown file format"
        log_error "Expected ZIP (504b) or gzip (1f8b), Got: $FIRST_TWO"
        write_status "FAILED: Unknown file format" 100
        exit 1
    fi
    
    # Clean and create cache directory (same as native: os.RemoveAll(CacheDir); os.MkdirAll(CacheDir))
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    
    # Extract to cache directory
    log_info "Extracting to cache directory..."
    write_status "Extracting files" 60
    
    EXTRACT_STATUS=0
    if [ "$IS_ZIP" = "1" ]; then
        if command -v unzip > /dev/null 2>&1; then
            # Test ZIP integrity first
            if ! unzip -t "$PACKAGE" > /dev/null 2>&1; then
                log_error "ZIP file is corrupted or invalid"
                log_error "Try re-downloading the file"
                write_status "FAILED: ZIP file corrupted" 100
                rm -rf "$CACHE_DIR"
                exit 1
            fi
            
            # Extract ZIP file to cache
            if ! unzip -o "$PACKAGE" -d "$CACHE_DIR"; then
                log_error "Failed to extract ZIP file"
                write_status "FAILED: ZIP extraction failed" 100
                EXTRACT_STATUS=1
            fi
        else
            log_error "unzip command not found"
            write_status "FAILED: unzip not available" 100
            rm -rf "$CACHE_DIR"
            exit 1
        fi
    else
        # Extract tar.gz file to cache
        if ! tar -xzf "$PACKAGE" -C "$CACHE_DIR"; then
            log_error "Failed to extract tar.gz file"
            write_status "FAILED: tar extraction failed" 100
            EXTRACT_STATUS=1
        fi
    fi
    
    if [ "$EXTRACT_STATUS" != "0" ]; then
        log_error "Extraction failed"
        rm -rf "$CACHE_DIR"
        exit 1
    fi
    
    # Find the extracted kvmapp directory (native gets first directory from tar)
    # Package should contain: kvmapp/server/..., kvmapp/kvm_system/..., etc.
    EXTRACTED_DIR=""
    if [ -d "$CACHE_DIR/kvmapp" ]; then
        EXTRACTED_DIR="$CACHE_DIR/kvmapp"
        log_info "Found kvmapp directory in package"
    else
        # Fallback: files might be directly in cache dir (old format)
        EXTRACTED_DIR="$CACHE_DIR"
        log_info "Using cache directory directly (flat package structure)"
    fi
    
    # Preserve kvm_system from backup if not in package
    # (kvm_system requires cross-compilation and may not be in dev builds)
    KVM_SYSTEM_PRESERVED=0
    if [ -d "$BACKUP_DIR/kvm_system" ] && [ -f "$BACKUP_DIR/kvm_system/kvm_system" ]; then
        if [ ! -d "$EXTRACTED_DIR/kvm_system" ] || [ ! -f "$EXTRACTED_DIR/kvm_system/kvm_system" ]; then
            log_info "Preserving kvm_system from backup (not in update package)..."
            rm -rf "$EXTRACTED_DIR/kvm_system" 2>/dev/null
            cp -a "$BACKUP_DIR/kvm_system" "$EXTRACTED_DIR/kvm_system"
            KVM_SYSTEM_PRESERVED=1
        fi
    fi
    
    # Move extracted files to /kvmapp (same as native: MoveFilesRecursively(dir, AppDir))
    log_info "Installing files to $KVMAPP_DIR..."
    write_status "Moving files" 70
    
    # Remove any existing kvmapp directory first (should already be moved to backup)
    rm -rf "$KVMAPP_DIR"
    
    # Move the extracted directory to /kvmapp
    if ! mv "$EXTRACTED_DIR" "$KVMAPP_DIR"; then
        log_error "Failed to move files to $KVMAPP_DIR"
        # Try to restore from backup
        if [ -d "$BACKUP_DIR" ]; then
            log_info "Attempting to restore from backup..."
            mv "$BACKUP_DIR" "$KVMAPP_DIR"
        fi
        rm -rf "$CACHE_DIR"
        exit 1
    fi
    
    # Clean up cache directory (same as native: defer os.RemoveAll(CacheDir))
    rm -rf "$CACHE_DIR"
    
    log_info "Files installed successfully"
    if [ "$KVM_SYSTEM_PRESERVED" = "1" ]; then
        log_info "Note: kvm_system was preserved from previous installation"
    fi
    write_status "Files installed" 75
}

# Install kvmapp from unpacked directory
install_kvmapp_from_dir() {
    SRC_DIR="$1"
    
    log_info "Installing from directory: $SRC_DIR"
    write_status "Installing from directory" 50
    
    # Verify source directory exists
    if [ ! -d "$SRC_DIR" ]; then
        log_error "Source directory not found: $SRC_DIR"
        write_status "FAILED: Source directory not found" 100
        exit 1
    fi
    
    # Check if it looks like a kvmapp directory
    if [ ! -f "$SRC_DIR/NanoKVM-Server" ] && [ ! -d "$SRC_DIR/server" ] && [ ! -d "$SRC_DIR/kvm_system" ]; then
        log_warn "Directory doesn't appear to contain kvmapp files"
        log_warn "Expected to find NanoKVM-Server, server/, or kvm_system/"
    fi
    
    # Remove old kvmapp
    if [ -d "$KVMAPP_DIR" ]; then
        log_info "Removing old installation..."
        rm -rf "$KVMAPP_DIR"
    fi
    
    # Copy files from source directory
    log_info "Copying files..."
    write_status "Copying files" 60
    mkdir -p "$KVMAPP_DIR"
    cp -a "$SRC_DIR/"* "$KVMAPP_DIR/"
    
    log_info "Files copied successfully"
    write_status "Files copied" 70
}

# Set correct permissions (same as native: ChmodRecursively(AppDir, 0o755))
set_permissions() {
    log_info "Setting permissions..."
    write_status "Setting permissions" 80
    
    # Native update sets chmod 755 on all files recursively
    # This makes everything executable, which is simpler and matches native behavior
    chmod -R 755 "$KVMAPP_DIR"
    
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
    
    # Check for backup at /root/old (matches native backup location)
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "No backup found at $BACKUP_DIR"
        write_status "FAILED: No backup found" 100
        exit 1
    fi
    
    log_info "Restoring from: $BACKUP_DIR"
    
    stop_services
    
    if [ -d "$KVMAPP_DIR" ]; then
        rm -rf "$KVMAPP_DIR"
    fi
    
    # Move backup back to /kvmapp
    mv "$BACKUP_DIR" "$KVMAPP_DIR"
    set_permissions
    start_services
    
    log_info "Rollback completed"
    write_status "Rollback completed" 100
}

# List available backups
list_backups() {
    echo "Available backups:"
    
    if [ -d "$BACKUP_DIR" ]; then
        size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        version=$(get_dir_version "$BACKUP_DIR")
        printf "  %s (version: %s, size: %s)\n" "$BACKUP_DIR" "$version" "$size"
    else
        echo "  No backup found at $BACKUP_DIR"
    fi
}

# Get version from directory
get_dir_version() {
    DIR="$1"
    if [ -d "$DIR" ] && [ -f "$DIR/version" ]; then
        tr -d '\n' < "$DIR/version" 2>/dev/null
    else
        echo "unknown"
    fi
}

# Run the actual upgrade process
do_upgrade() {
    SOURCE="$1"
    IS_DIR="$2"
    
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
    if [ "$IS_DIR" = "1" ]; then
        NEW_VERSION=$(get_dir_version "$SOURCE")
    else
        NEW_VERSION=$(get_tarball_version "$SOURCE")
    fi
    log_info "Updating from version: $EXISTING_VERSION"
    log_info "Updating to version:   $NEW_VERSION"
    log_info ""
    write_status "Upgrading from $EXISTING_VERSION to $NEW_VERSION" 5
    
    stop_services
    create_backup
    
    if [ "$IS_DIR" = "1" ]; then
        install_kvmapp_from_dir "$SOURCE"
    else
        install_kvmapp "$SOURCE"
    fi
    
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
            --dir)
                shift
                if [ -z "$1" ]; then
                    echo "Error: --dir requires a directory path argument"
                    exit 1
                fi
                SOURCE_DIR="$1"
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
    
    # Determine the source
    if [ -n "$SOURCE_DIR" ]; then
        # Using unpacked directory - no tarball needed
        :
    elif [ -n "$PACKAGE_URL" ]; then
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
    
    # If no source specified, show usage
    if [ -z "$TARBALL" ] && [ -z "$PACKAGE_URL" ] && [ -z "$SOURCE_DIR" ]; then
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
    
    # If using directory mode, skip tarball check
    if [ -n "$SOURCE_DIR" ]; then
        # Verify source directory exists
        if [ ! -d "$SOURCE_DIR" ]; then
            echo "Error: Directory not found: $SOURCE_DIR"
            exit 1
        fi
    elif [ ! -f "$TARBALL" ]; then
        echo "Error: File not found: $TARBALL"
        echo ""
        echo "Make sure you've copied the tarball to the device first:"
        echo "  scp nanokvm-kvmapp-update.tar.gz root@<ip>:/tmp/"
        echo ""
        echo "Or use --url to download directly:"
        echo "  $0 --url <download_url>"
        echo ""
        echo "Or use --dir for an unpacked directory:"
        echo "  $0 --dir /tmp/kvmapp"
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
        if [ -n "$SOURCE_DIR" ]; then
            ASYNC_CMD="$ASYNC_CMD SOURCE_DIR='$SOURCE_DIR'"
        fi
        ASYNC_CMD="$ASYNC_CMD '$0' '$TARBALL'"
        
        # Use nohup and redirect all output to log file
        nohup sh -c "$ASYNC_CMD" > /dev/null 2>&1 &
        
        echo "Upgrade started in background (PID: $!)"
        exit 0
    else
        # Run synchronously
        if [ -n "$SOURCE_DIR" ]; then
            do_upgrade "$SOURCE_DIR" "1"
        else
            do_upgrade "$TARBALL" "0"
        fi
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
        do_upgrade "$TARBALL" "0"
    elif [ -n "$SOURCE_DIR" ]; then
        do_upgrade "$SOURCE_DIR" "1"
    else
        TARBALL="$1"
        do_upgrade "$TARBALL" "0"
    fi
else
    # Normal entry point
    main "$@"
fi
