#!/bin/bash
#
# ARM64 CAPI Image Builder - Local Build Automation
#
# This script automates the process of building and testing an ARM64
# Cluster API (CAPI) image for Kubernetes deployment on Grace Hopper / DGX systems.
#
# Supports two build modes:
#   1. Local Build: Uses QEMU TCG emulation on x86 (~30-60 min)
#   2. Docker Build: Runs build inside Docker container (~30-60 min)
#
# Prerequisites (Local build):
#   - qemu-system-arm, qemu-efi-aarch64
#   - packer, ansible, sshpass, genisoimage
#   - Run ./scripts/install-local-deps.sh to install
#
# Prerequisites (Docker build):
#   - Docker installed and running
#
# Usage:
#   ./build-and-test.sh --local [options]
#   ./build-and-test.sh --local-docker [options]
#
# Options:
#   --local           Build locally on x86 using QEMU TCG emulation
#   --local-docker    Build locally inside Docker container
#   --skip-build      Skip image build (use existing image)
#   --skip-test       Skip validation tests
#   --k8s-version     Kubernetes version (default: v1.32.4)
#
# Examples:
#   ./build-and-test.sh --local
#   ./build-and-test.sh --local --k8s-version v1.33.0
#   ./build-and-test.sh --local-docker
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Build configuration
K8S_VERSION="${K8S_VERSION:-v1.32.4}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
CNI_VERSION="${CNI_VERSION:-1.6.0}"
CRICTL_VERSION="${CRICTL_VERSION:-1.32.0}"

# Options
SKIP_BUILD=false
SKIP_TEST=false
LOCAL_BUILD=false
LOCAL_DOCKER_BUILD=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Local Build Functions
# =============================================================================
check_local_prerequisites() {
    log_info "Checking local build prerequisites..."

    local missing=()

    command -v qemu-system-aarch64 >/dev/null 2>&1 || missing+=("qemu-system-arm")
    command -v packer >/dev/null 2>&1 || missing+=("packer")
    command -v ansible >/dev/null 2>&1 || missing+=("ansible")
    command -v sshpass >/dev/null 2>&1 || missing+=("sshpass")
    command -v genisoimage >/dev/null 2>&1 || missing+=("genisoimage")

    # Check for EFI firmware
    local efi_found=false
    for path in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
        if [[ -f "$path" ]]; then
            efi_found=true
            break
        fi
    done
    [[ "$efi_found" == "true" ]] || missing+=("qemu-efi-aarch64")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing local build dependencies: ${missing[*]}"
        log_info "Run: ./scripts/install-local-deps.sh"
        exit 1
    fi

    log_success "All local prerequisites met"
}

print_local_banner() {
    local total_threads=$(nproc)
    local qemu_cpus=$((total_threads - 2))
    [[ $qemu_cpus -lt 4 ]] && qemu_cpus=4
    [[ $qemu_cpus -gt 16 ]] && qemu_cpus=16

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     ARM64 CAPI Image Builder - Local x86 TCG Emulation            ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Host Threads: $(printf '%-5s' "$total_threads")   Emulated ARM64 Cores: $(printf '%-5s' "$qemu_cpus")            ║"
    echo "║  Kubernetes:   $(printf '%-20s' "$K8S_VERSION")                           ║"
    echo "║  Target: Grace Hopper / DGX ARM64 Systems                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
}

run_local_build() {
    log_info "Starting local ARM64 CAPI image build..."
    log_warn "This will take 30-60 minutes using QEMU TCG emulation"

    K8S_VERSION=$K8S_VERSION \
    CONTAINERD_VERSION=$CONTAINERD_VERSION \
    CNI_VERSION=$CNI_VERSION \
    CRICTL_VERSION=$CRICTL_VERSION \
    "$SCRIPT_DIR/build-local.sh" 2>&1 | tee "$PROJECT_DIR/build.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Local build failed. Check build.log for details."
        exit 1
    fi

    log_success "Local build completed successfully"
}

run_local_tests() {
    log_info "Running local image validation tests..."

    if [[ -x "$SCRIPT_DIR/validate-image.sh" ]]; then
        "$SCRIPT_DIR/validate-image.sh" 2>&1 | tee "$PROJECT_DIR/test.log"

        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            log_success "All tests passed!"
        else
            log_warn "Some tests may have failed. Check test.log for details."
        fi
    else
        log_warn "Validation script not found, skipping tests"
    fi
}

# =============================================================================
# Docker Build Functions
# =============================================================================
check_docker_prerequisites() {
    log_info "Checking Docker prerequisites..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        log_info "Install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running or user lacks permissions"
        log_info "Try: sudo systemctl start docker"
        log_info "Or add user to docker group: sudo usermod -aG docker \$USER"
        exit 1
    fi

    log_success "Docker prerequisites met"
}

print_local_docker_banner() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     ARM64 CAPI Image Builder - Docker Container Build             ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Build Environment: Docker (isolated, reproducible)               ║"
    echo "║  Kubernetes:   $(printf '%-20s' "$K8S_VERSION")                           ║"
    echo "║  Target: Grace Hopper / DGX ARM64 Systems                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
}

run_local_docker_build() {
    log_info "Starting Docker-based ARM64 CAPI image build..."
    log_warn "This will take 30-60 minutes using QEMU TCG emulation inside Docker"

    K8S_VERSION=$K8S_VERSION \
    CONTAINERD_VERSION=$CONTAINERD_VERSION \
    CNI_VERSION=$CNI_VERSION \
    CRICTL_VERSION=$CRICTL_VERSION \
    "$SCRIPT_DIR/build-local-docker.sh" 2>&1 | tee "$PROJECT_DIR/build.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Docker build failed. Check build.log for details."
        exit 1
    fi

    log_success "Docker build completed successfully"
}

# =============================================================================
# Argument Parsing
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-test)
                SKIP_TEST=true
                shift
                ;;
            --k8s-version)
                K8S_VERSION="$2"
                shift 2
                ;;
            --local)
                LOCAL_BUILD=true
                shift
                ;;
            --local-docker)
                LOCAL_DOCKER_BUILD=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 --local [options]"
                echo "       $0 --local-docker [options]"
                echo ""
                echo "Build Modes (one required):"
                echo "  --local             Build locally on x86 using QEMU TCG emulation"
                echo "  --local-docker      Build locally inside Docker container (no host deps)"
                echo ""
                echo "Options:"
                echo "  --skip-build        Skip image build (use existing image)"
                echo "  --skip-test         Skip validation tests"
                echo "  --k8s-version       Kubernetes version (default: v1.32.4)"
                echo ""
                echo "Examples:"
                echo "  # Local build (uses QEMU emulation)"
                echo "  $0 --local"
                echo "  $0 --local --k8s-version v1.33.0"
                echo ""
                echo "  # Docker build (isolated, reproducible)"
                echo "  $0 --local-docker"
                echo "  $0 --local-docker --k8s-version v1.33.0"
                echo ""
                echo "Prerequisites for local build:"
                echo "  Run: ./scripts/install-local-deps.sh"
                echo ""
                echo "Prerequisites for Docker build:"
                echo "  Docker installed and running"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate that a build mode is specified
    if [[ "$LOCAL_BUILD" == "false" ]] && [[ "$LOCAL_DOCKER_BUILD" == "false" ]]; then
        log_error "Must specify a build mode: --local or --local-docker"
        log_error "Use --help for usage information"
        exit 1
    fi

    # Cannot specify both
    if [[ "$LOCAL_BUILD" == "true" ]] && [[ "$LOCAL_DOCKER_BUILD" == "true" ]]; then
        log_error "Cannot specify both --local and --local-docker"
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"

    # Handle local build
    if [[ "$LOCAL_BUILD" == "true" ]]; then
        print_local_banner
        check_local_prerequisites

        START_TIME=$(date +%s)

        # Build
        if [[ "$SKIP_BUILD" == "false" ]]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Building ARM64 CAPI Image (Local x86 TCG Emulation)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            run_local_build
        else
            log_warn "Skipping image build"
        fi

        # Test
        if [[ "$SKIP_TEST" == "false" ]]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Validating Image"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            run_local_tests
        else
            log_warn "Skipping tests"
        fi

        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))

        echo ""
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║                     LOCAL BUILD COMPLETE                          ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  Duration: $((DURATION / 60))m $((DURATION % 60))s"
        echo ""
        echo "  Output files in: $PROJECT_DIR/output/"
        ls -lh "$PROJECT_DIR/output"/*.{qcow2,raw,vmdk,ova} 2>/dev/null || ls -lh "$PROJECT_DIR/output/" 2>/dev/null || true
        echo ""
        exit 0
    fi

    # Handle Docker build
    if [[ "$LOCAL_DOCKER_BUILD" == "true" ]]; then
        print_local_docker_banner
        check_docker_prerequisites

        START_TIME=$(date +%s)

        # Build
        if [[ "$SKIP_BUILD" == "false" ]]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Building ARM64 CAPI Image (Docker Container)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            run_local_docker_build
        else
            log_warn "Skipping image build"
        fi

        # Test
        if [[ "$SKIP_TEST" == "false" ]]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Validating Image"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            run_local_tests
        else
            log_warn "Skipping tests"
        fi

        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))

        echo ""
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║                     DOCKER BUILD COMPLETE                         ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  Duration: $((DURATION / 60))m $((DURATION % 60))s"
        echo ""
        echo "  Output files in: $PROJECT_DIR/output/"
        ls -lh "$PROJECT_DIR/output"/*.{qcow2,raw,vmdk,ova} 2>/dev/null || ls -lh "$PROJECT_DIR/output/" 2>/dev/null || true
        echo ""
        exit 0
    fi
}

main "$@"
