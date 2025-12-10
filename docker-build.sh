#!/bin/bash
# NanoKVM Build Script for Docker
# This script builds all NanoKVM components inside the Docker container

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

WORKSPACE="${WORKSPACE:-/workspace}"
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"

log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Ensure we're in the workspace
cd "$WORKSPACE"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# ------------------------------------------------------------------------------
# Build Frontend
# ------------------------------------------------------------------------------
build_frontend() {
    log_info "Building frontend..."
    
    if [ ! -d "web" ]; then
        log_error "web directory not found"
        return 1
    fi
    
    cd "$WORKSPACE/web"
    pnpm install --frozen-lockfile
    pnpm build
    
    log_success "Frontend built successfully"
    cd "$WORKSPACE"
}

# ------------------------------------------------------------------------------
# Build Go Server
# ------------------------------------------------------------------------------
build_server() {
    log_info "Building Go server for RISC-V..."
    
    if [ ! -d "server" ]; then
        log_error "server directory not found"
        return 1
    fi
    
    cd "$WORKSPACE/server"
    
    # Fix Git ownership issue when running in Docker with mounted volumes
    # This is needed because the container user differs from the host user
    git config --global --add safe.directory "$WORKSPACE" 2>/dev/null || true
    
    # Set cross-compilation environment
    export CGO_ENABLED=1
    export GOOS=linux
    export GOARCH=riscv64
    export CC="riscv64-linux-musl-gcc"
    export CGO_CFLAGS="-mcpu=c906fdv -march=rv64imafdcv0p7xthead -mcmodel=medany -mabi=lp64d"
    
    # Build the binary with -buildvcs=false to avoid Git VCS stamping issues
    # when running in Docker with mounted volumes
    go build -buildvcs=false -o NanoKVM-Server -v
    
    if [ ! -f "NanoKVM-Server" ]; then
        log_error "Server build failed - binary not found"
        return 1
    fi
    
    # Patch RPATH for dynamic library loading
    patchelf --add-rpath '$ORIGIN/dl_lib' NanoKVM-Server
    
    log_success "Server built successfully"
    file NanoKVM-Server
    cd "$WORKSPACE"
}

# ------------------------------------------------------------------------------
# Build EDID Utility
# ------------------------------------------------------------------------------
build_edid_tool() {
    log_info "Building EDID update utility..."
    
    if [ ! -d "tools/nanokvm_update_edid" ]; then
        log_info "EDID tool directory not found, skipping"
        return 0
    fi
    
    cd "$WORKSPACE/tools/nanokvm_update_edid"
    make clean || true
    make
    
    log_success "EDID utility built successfully"
    cd "$WORKSPACE"
}

# ------------------------------------------------------------------------------
# Assemble kvmapp Package
# ------------------------------------------------------------------------------
assemble_kvmapp() {
    log_info "Assembling kvmapp update package..."
    
    KVMAPP_ROOT="$OUTPUT_DIR/kvmapp"
    WEB_ROOT="$KVMAPP_ROOT/server/web"
    SERVER_ROOT="$KVMAPP_ROOT/server"
    
    # Copy base kvmapp structure
    mkdir -p "$KVMAPP_ROOT"
    if [ -d "kvmapp" ]; then
        cp -r kvmapp/. "$KVMAPP_ROOT/"
    fi
    
    # Add web frontend
    mkdir -p "$WEB_ROOT"
    if [ -d "web/dist" ]; then
        cp -r web/dist/. "$WEB_ROOT/"
    fi
    
    # Add server binary and dependencies
    mkdir -p "$SERVER_ROOT"
    if [ -f "server/NanoKVM-Server" ]; then
        cp server/NanoKVM-Server "$SERVER_ROOT/"
    fi
    if [ -d "server/dl_lib" ]; then
        cp -r server/dl_lib "$SERVER_ROOT/"
    fi
    
    # Copy server config files
    for cfg in server/config/*.yaml server/config/*.yml; do
        [ -f "$cfg" ] && cp "$cfg" "$SERVER_ROOT/" || true
    done
    
    # Create version file
    if git rev-parse --short HEAD &>/dev/null; then
        echo "dev-$(git rev-parse --short HEAD)" > "$KVMAPP_ROOT/version"
    else
        echo "dev-local" > "$KVMAPP_ROOT/version"
    fi
    
    # Set executable permissions
    chmod +x "$KVMAPP_ROOT/kvm_system/"* 2>/dev/null || true
    chmod +x "$SERVER_ROOT/NanoKVM-Server" 2>/dev/null || true
    chmod +x "$KVMAPP_ROOT/system/init.d/"* 2>/dev/null || true
    
    # Add tools
    mkdir -p "$OUTPUT_DIR/tools"
    if [ -f "tools/nanokvm_update_edid/nanokvm_update_edid" ]; then
        cp tools/nanokvm_update_edid/nanokvm_update_edid "$OUTPUT_DIR/tools/"
    fi
    
    # Create update package
    cd "$OUTPUT_DIR"
    tar -czf nanokvm-kvmapp-update.tar.gz -C kvmapp .
    tar -czf nanokvm-artifacts.tar.gz .
    
    log_success "kvmapp package created: $OUTPUT_DIR/nanokvm-kvmapp-update.tar.gz"
    ls -la "$OUTPUT_DIR"/*.tar.gz
    
    cd "$WORKSPACE"
}

# ------------------------------------------------------------------------------
# Main Build Flow
# ------------------------------------------------------------------------------
main() {
    log_info "Starting NanoKVM build..."
    log_info "Workspace: $WORKSPACE"
    log_info "Output: $OUTPUT_DIR"
    
    # Fix Git ownership issue when running in Docker with mounted volumes
    # This is needed because the container user differs from the host user
    git config --global --add safe.directory "$WORKSPACE" 2>/dev/null || true
    
    # Check if we have the source
    if [ ! -f "$WORKSPACE/server/go.mod" ]; then
        log_error "Source code not found in $WORKSPACE"
        log_info "Mount your NanoKVM source to /workspace"
        exit 1
    fi
    
    # Build components
    build_frontend
    build_server
    build_edid_tool
    assemble_kvmapp
    
    log_success "Build completed successfully!"
    log_info "Artifacts available in: $OUTPUT_DIR"
}

# Run if called directly
if [ "$(basename "$0")" = "docker-build.sh" ] || [ "$(basename "$0")" = "build-nanokvm" ]; then
    main "$@"
fi
