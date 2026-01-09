#!/bin/bash
#
# Docker Build Wrapper Script
#
# Builds ARM64 CAPI images inside a Docker container for reproducible builds.
# This script handles Docker/docker-compose detection and container orchestration.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Pass through environment variables with defaults
export K8S_VERSION="${K8S_VERSION:-v1.32.4}"
export CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
export CNI_VERSION="${CNI_VERSION:-1.6.0}"
export CRICTL_VERSION="${CRICTL_VERSION:-1.32.0}"
export RUNC_VERSION="${RUNC_VERSION:-1.2.8}"
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)

# Create output directories on host
mkdir -p "$PROJECT_DIR/output" "$PROJECT_DIR/local-build"

log_info "Starting Docker-based ARM64 CAPI image build..."
log_info "Kubernetes: $K8S_VERSION"
log_info "containerd: $CONTAINERD_VERSION"
log_info "CNI: $CNI_VERSION"

cd "$PROJECT_DIR"

# Try docker compose v2 first (preferred), then docker-compose legacy, then fallback
if docker compose version &> /dev/null 2>&1; then
    log_info "Using docker compose (v2)..."
    docker compose -f docker/docker-compose.yml up --build --abort-on-container-exit
    exit_code=$?
elif command -v docker-compose &> /dev/null; then
    log_info "Using docker-compose (legacy)..."
    docker-compose -f docker/docker-compose.yml up --build --abort-on-container-exit
    exit_code=$?
else
    log_info "Using docker run directly..."

    # Build the image
    log_info "Building Docker image..."
    docker build \
        --build-arg UID=$(id -u) \
        --build-arg GID=$(id -g) \
        --build-arg PACKER_VERSION=1.10.0 \
        -t capi-arm64-builder \
        -f docker/Dockerfile .

    # Run the container
    log_info "Running build container..."
    docker run --rm \
        --privileged \
        -v "$PROJECT_DIR/output:/build/output" \
        -v "$PROJECT_DIR/local-build:/build/local-build" \
        -e K8S_VERSION \
        -e CONTAINERD_VERSION \
        -e CNI_VERSION \
        -e CRICTL_VERSION \
        -e RUNC_VERSION \
        --tmpfs /tmp:size=10G \
        --shm-size=2g \
        capi-arm64-builder
    exit_code=$?
fi

if [[ $exit_code -eq 0 ]]; then
    log_success "Docker build completed successfully!"
    echo ""
    echo "Output files:"
    ls -lh "$PROJECT_DIR/output/"*.{qcow2,raw,vmdk,ova} 2>/dev/null || ls -lh "$PROJECT_DIR/output/"
else
    log_error "Docker build failed with exit code $exit_code"
    exit $exit_code
fi
