# NanoKVM Build Environment
# This Dockerfile provides a complete build environment for NanoKVM
# including cross-compilation tools for RISC-V (C906 processor)

FROM ubuntu:22.04

LABEL maintainer="NanoKVM Team"
LABEL description="Build environment for NanoKVM with RISC-V cross-compilation support"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Set build environment variables
ENV CGO_ENABLED=1
ENV GOOS=linux
ENV GOARCH=riscv64
ENV CC=riscv64-linux-musl-gcc
# Use standard RISC-V flags compatible with musl.cc toolchain
# Note: T-Head specific flags like -mcpu=c906fdv require T-Head's custom toolchain
ENV CGO_CFLAGS="-march=rv64gc -mabi=lp64d"

# Go and Node versions
ENV GO_VERSION=1.22.5
ENV NODE_VERSION=20

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    wget \
    git \
    gcc-riscv64-linux-gnu \
    patchelf \
    xz-utils \
    kpartx \
    parted \
    e2fsprogs \
    dosfstools \
    ca-certificates \
    gnupg \
    file \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm
RUN npm install -g pnpm@9

# Install Go
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Download and install RISC-V musl toolchain
# Using multiple mirrors for reliability
# Set TOOLCHAIN_URL as build arg to use alternative mirror (recommended)
ARG TOOLCHAIN_URL=""
RUN mkdir -p /opt/toolchain && cd /opt/toolchain && \
    DOWNLOAD_SUCCESS=0 && \
    if [ -n "$TOOLCHAIN_URL" ]; then \
        echo "Using custom toolchain URL from build arg..." && \
        if curl -fsSL --retry 3 --connect-timeout 30 --max-time 300 "$TOOLCHAIN_URL" -o toolchain.tgz; then \
            DOWNLOAD_SUCCESS=1; \
        else \
            echo "WARNING: Custom toolchain URL failed, falling back to public mirrors..."; \
        fi; \
    fi && \
    if [ "$DOWNLOAD_SUCCESS" = "0" ]; then \
        echo "Trying primary mirror: musl.cc..." && \
        curl -fsSL --retry 2 --connect-timeout 30 --max-time 300 \
            "https://musl.cc/riscv64-linux-musl-cross.tgz" \
            -o toolchain.tgz && DOWNLOAD_SUCCESS=1 || \
        (echo "Primary mirror failed, trying secondary mirror: more.musl.cc..." && \
        curl -fsSL --retry 2 --connect-timeout 30 --max-time 300 \
            "https://more.musl.cc/11.2.1/x86_64-linux-musl/riscv64-linux-musl-cross.tgz" \
            -o toolchain.tgz && DOWNLOAD_SUCCESS=1) || \
        (echo "Secondary mirror failed, trying GitHub mirror..." && \
        curl -fsSL --retry 2 --connect-timeout 30 --max-time 300 \
            "https://github.com/richfelker/musl-cross-make/releases/download/v0.9.9/riscv64-linux-musl-cross.tgz" \
            -o toolchain.tgz && DOWNLOAD_SUCCESS=1); \
    fi && \
    if [ "$DOWNLOAD_SUCCESS" = "0" ]; then \
        echo "ERROR: All toolchain mirrors failed. Please set TOOLCHAIN_URL build arg."; \
        exit 1; \
    fi && \
    tar xzf toolchain.tgz && \
    rm toolchain.tgz

# Add musl toolchain to PATH
ENV PATH="/opt/toolchain/riscv64-linux-musl-cross/bin:${PATH}"

# Create working directory
WORKDIR /workspace

# Verify installations
RUN echo "=== Build Environment ===" && \
    echo "Go version:" && go version && \
    echo "Node version:" && node --version && \
    echo "pnpm version:" && pnpm --version && \
    echo "GNU RISC-V GCC:" && riscv64-linux-gnu-gcc --version | head -1 && \
    echo "Musl RISC-V GCC:" && riscv64-linux-musl-gcc --version | head -1 && \
    echo "patchelf version:" && patchelf --version && \
    echo "========================="

# Copy build script
COPY docker-build.sh /usr/local/bin/build-nanokvm
RUN chmod +x /usr/local/bin/build-nanokvm

# Default command
CMD ["/bin/bash"]
