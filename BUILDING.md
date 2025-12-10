# Building NanoKVM

This document describes how to build NanoKVM components and create flashable OS images.

## Overview

NanoKVM consists of several components:

- **Web Frontend** - React/TypeScript web interface
- **Go Backend Server** - NanoKVM-Server binary
- **kvm_system** - System monitoring and OLED controller (requires MaixCDK)
- **EDID Utility** - Tool for updating EDID settings
- **OS Image** - Complete flashable SD card image

## Quick Start with Docker (Recommended)

The easiest way to build NanoKVM is using the provided Docker image:

```bash
# Build using docker-compose
docker-compose run --rm build

# Or manually with docker
docker build -t nanokvm-builder .
docker run --rm -v "$(pwd):/workspace" -v "$(pwd)/output:/workspace/output" nanokvm-builder build-nanokvm
```

Build artifacts will be in the `output/` directory.

## CI/CD Build (GitHub Actions)

The repository includes GitHub Actions workflows that automatically build using Docker and Azure Container Registry.

### Workflows

1. **docker-build.yml** - Builds and pushes the Docker build environment image to ACR
   - Triggered on changes to `Dockerfile` or `docker-build.sh`
   - Can be triggered manually or called by other workflows
   - Caches Docker layers for faster builds

2. **pr-build.yml** - Main build workflow for NanoKVM
   - Calls `docker-build.yml` to ensure Docker image is available
   - Uses the Docker image to build all NanoKVM components
   - Optionally creates flashable OS images

### Build Artifacts

- `nanokvm-kvmapp-{sha}.tar.gz` - Update package for existing installations
- `nanokvm-build-{sha}` - All build artifacts
- `nanokvm-os-image-{sha}` - Flashable SD card image (manual trigger only)

### Azure Container Registry Setup

The CI workflow uses Azure Container Registry (ACR) to store and cache the Docker build image. To configure:

1. **Create an Azure Container Registry**:
   ```bash
   az acr create --resource-group <rg-name> --name <acr-name> --sku Basic
   ```

2. **Enable admin access** (or use service principal):
   ```bash
   az acr update --name <acr-name> --admin-enabled true
   ```

3. **Get credentials**:
   ```bash
   az acr credential show --name <acr-name>
   ```

4. **Add GitHub Secrets**:
   - `ACR_REGISTRY`: `<acr-name>.azurecr.io`
   - `ACR_USERNAME`: Admin username or service principal ID
   - `ACR_PASSWORD`: Admin password or service principal secret
   - `TOOLCHAIN_URL` (optional): Custom URL for RISC-V musl toolchain (e.g., Azure blob storage URL with SAS token)

### Azure Storage Setup (for artifact uploads)

To enable uploading build artifacts and OS images to Azure Blob Storage:

1. **Create a Storage Account** (if not already exists):
   ```bash
   az storage account create --name <storage-name> --resource-group <rg-name> --sku Standard_LRS
   ```

2. **Create a container for builds**:
   ```bash
   az storage container create --name nanokvm-builds --account-name <storage-name>
   ```

3. **Get the connection string**:
   ```bash
   az storage account show-connection-string --name <storage-name> --resource-group <rg-name>
   ```

4. **Add GitHub Secrets**:
   - `AZURE_STORAGE_CONNECTION_STRING`: The full connection string from step 3
   - `AZURE_STORAGE_CONTAINER`: Container name (default: `nanokvm-builds`)

Artifacts will be uploaded to: `<container>/<branch>/<version>/`

### Manual Workflow Triggers

To build a flashable OS image:

1. Go to Actions → "Build NanoKVM preview artifacts"
2. Click "Run workflow"
3. Check "Build flashable OS image"
4. Check "Upload artifacts to Azure Storage" (enabled by default)
5. Click "Run workflow"

To force rebuild the Docker image:

1. Go to Actions → "Build Docker Image"
2. Click "Run workflow"
3. Check "Force rebuild Docker image"
4. Click "Run workflow"

Or via the main build workflow:

1. Go to Actions → "Build NanoKVM preview artifacts"
2. Click "Run workflow"
3. Check "Force rebuild Docker image"
4. Click "Run workflow"

## Local Development Build

### Option 1: Using Docker (Recommended)

```bash
# Build the Docker image
docker build -t nanokvm-builder .

# Run the build
docker run --rm \
  -v "$(pwd):/workspace" \
  -v "$(pwd)/output:/workspace/output" \
  nanokvm-builder build-nanokvm

# Or use docker-compose
docker-compose run --rm build

# For interactive debugging
docker-compose run --rm shell
```

### Option 2: Manual Build

#### Prerequisites

- Linux x86-64 (Ubuntu 22.04+ recommended)
- Node.js 20+
- pnpm 9+
- Go 1.22.5+
- RISC-V cross-compiler toolchain

#### Installing the RISC-V Toolchain

**Option A: Using musl.cc pre-built toolchain (recommended for Go)**

```bash
# Primary mirror
curl -fSL https://musl.cc/riscv64-linux-musl-cross.tgz | tar xz

# Alternative mirror (if primary is unavailable)
# curl -fSL https://more.musl.cc/11.2.1/x86_64-linux-musl/riscv64-linux-musl-cross.tgz | tar xz

export PATH="$PWD/riscv64-linux-musl-cross/bin:$PATH"
```

> **Note**: The musl.cc server can occasionally be slow or unavailable. The CI workflow includes retry logic and fallback mirrors to handle this.

**Option B: Using Sophgo toolchain**

```bash
# Download from Sophgo
curl -L https://sophon-file.sophon.cn/sophon-prod-s3/drive/23/03/07/16/host-tools.tar.gz | tar xz
export PATH="$PWD/host-tools/gcc/riscv64-linux-musl-x86_64/bin:$PATH"
```

**Option C: Using system package (for EDID utility only)**

```bash
sudo apt-get install gcc-riscv64-linux-gnu
```

#### Building the Frontend

```bash
cd web
pnpm install --frozen-lockfile
pnpm build
# Output: web/dist/
```

#### Building the Go Server

```bash
cd server

# Set up cross-compilation environment
export CGO_ENABLED=1
export GOOS=linux
export GOARCH=riscv64
export CC="riscv64-linux-musl-gcc"  # or riscv64-unknown-linux-musl-gcc
export CGO_CFLAGS="-mcpu=c906fdv -march=rv64imafdcv0p7xthead -mcmodel=medany -mabi=lp64d"

# Build
go build -o NanoKVM-Server -v

# Patch RPATH for dynamic library loading
patchelf --add-rpath '$ORIGIN/dl_lib' NanoKVM-Server
```

#### Building the EDID Utility

```bash
cd tools/nanokvm_update_edid
make clean
make
# Output: nanokvm_update_edid
```

#### Building kvm_system (requires MaixCDK)

The `kvm_system` component requires the MaixCDK framework. See [support/sg2002/README.md](support/sg2002/README.md) for detailed instructions.

```bash
# Prerequisites: MaixCDK must be installed and configured
# See: https://github.com/sipeed/MaixCDK

export MAIXCDK_PATH=~/MaixCDK
export NanoKVM_PATH=~/NanoKVM

cd support/sg2002
./build kvm_system
```

## Creating a kvmapp Update Package

After building all components, assemble them into an update package:

```bash
mkdir -p output/kvmapp

# Copy base structure
cp -r kvmapp/. output/kvmapp/

# Add frontend
mkdir -p output/kvmapp/server/web
cp -r web/dist/. output/kvmapp/server/web/

# Add server binary
mkdir -p output/kvmapp/server
cp server/NanoKVM-Server output/kvmapp/server/

# Set permissions
chmod -R 755 output/kvmapp

# Create tarball
tar -czf nanokvm-update.tar.gz -C output/kvmapp .
```

## Creating a Flashable OS Image

### Using the CI/CD Pipeline (Recommended)

The GitHub Actions workflow can create flashable images by:
1. Downloading the official base NanoKVM OS image
2. Mounting the rootfs partition
3. Injecting the newly built kvmapp
4. Recompressing the image

### Manual Image Creation

For full control over the OS image, use the [LicheeSG-Nano-Build](https://github.com/scpcom/LicheeSG-Nano-Build) project:

```bash
git clone https://github.com/scpcom/LicheeSG-Nano-Build --depth=1
cd LicheeSG-Nano-Build
git submodule update --init --recursive --depth=1

# Build the complete image
./build-nanokvm.sh
# Output: install/soc_sg2002_licheervnano_sd/*.img
```

### Modifying an Existing Image

```bash
# Download base image
curl -L -o base.img.xz https://github.com/sipeed/NanoKVM/releases/download/NanoKVM/20240702_NanoKVM_Rev1_0_0.img.xz
xz -d base.img.xz

# Mount rootfs (partition 2)
LOOP_DEV=$(sudo losetup --find --show --partscan base.img)
sudo mount "${LOOP_DEV}p2" /mnt

# Replace kvmapp
sudo rm -rf /mnt/kvmapp
sudo tar -xzf nanokvm-update.tar.gz -C /mnt/kvmapp
sudo chmod -R 755 /mnt/kvmapp

# Cleanup
sudo umount /mnt
sudo losetup -d "$LOOP_DEV"

# Compress final image
xz -9 base.img
```

## Flashing the OS Image

### Using Balena Etcher (Recommended)

1. Download and install [Balena Etcher](https://etcher.io)
2. Select the `.img` or `.img.xz` file
3. Select your SD card
4. Click "Flash!"

### Using dd (Linux)

```bash
xzcat nanokvm-os.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

**Warning**: Replace `/dev/sdX` with your actual SD card device. Double-check before running!

## Updating an Existing NanoKVM

### Over-the-Air Update

1. Download the kvmapp update package
2. SSH into your NanoKVM
3. Stop the service: `/etc/init.d/S95nanokvm stop`
4. Backup existing: `mv /kvmapp /kvmapp.bak`
5. Extract new: `mkdir /kvmapp && tar -xzf nanokvm-update.tar.gz -C /kvmapp`
6. Set permissions: `chmod -R 755 /kvmapp`
7. Restart: `/etc/init.d/S95nanokvm restart`

### Using the Built-in Update Script

```bash
python3 /kvmapp/system/update-nanokvm.py
```

## Troubleshooting

### Go Build Fails with CGO Errors

Ensure you're using the musl toolchain, not glibc:
```bash
riscv64-linux-musl-gcc --version  # Should work
```

### patchelf Version Too Old

Install a newer version:
```bash
pip install patchelf
# or build from source
```

### Image Mount Fails

Install required tools:
```bash
sudo apt-get install kpartx parted e2fsprogs
```

### Docker Build Fails

If the Docker build fails due to toolchain download issues:
```bash
# Rebuild with no cache
docker build --no-cache -t nanokvm-builder .
```

## References

- [NanoKVM Wiki](https://wiki.sipeed.com/nanokvm)
- [MaixCDK Documentation](https://github.com/sipeed/MaixCDK)
- [LicheeSG-Nano-Build](https://github.com/scpcom/LicheeSG-Nano-Build)
- [Sipeed LicheeRV-Nano-Build](https://github.com/sipeed/LicheeRV-Nano-Build)
- [Azure Container Registry Documentation](https://docs.microsoft.com/en-us/azure/container-registry/)
