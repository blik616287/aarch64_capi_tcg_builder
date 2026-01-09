#!/bin/bash
#
# Install Local Build Dependencies
#
# One-time setup script for building ARM64 CAPI images on x86 hosts
# using QEMU TCG emulation.
#
set -euo pipefail

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

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║     ARM64 CAPI Image Builder - Local Dependencies Setup           ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    log_error "Cannot detect OS"
    exit 1
fi

log_info "Detected OS: $OS"
log_info "Installing QEMU ARM64 emulation and build dependencies..."

case $OS in
    ubuntu|debian)
        $SUDO apt-get update
        $SUDO apt-get install -y \
            qemu-system-arm \
            qemu-efi-aarch64 \
            qemu-utils \
            genisoimage \
            cloud-image-utils \
            ansible \
            sshpass \
            git \
            jq \
            curl \
            wget

        # Install Packer from HashiCorp repo if not present
        if ! command -v packer &>/dev/null; then
            log_info "Installing Packer from HashiCorp repository..."
            $SUDO apt-get install -y gpg
            wget -q -O- https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null || true
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | $SUDO tee /etc/apt/sources.list.d/hashicorp.list
            $SUDO apt-get update
            $SUDO apt-get install -y packer
        fi
        ;;
    fedora|rhel|centos)
        $SUDO dnf install -y \
            qemu-system-aarch64 \
            edk2-aarch64 \
            qemu-img \
            genisoimage \
            cloud-utils \
            ansible \
            sshpass \
            git \
            jq \
            curl \
            wget

        # Install Packer
        if ! command -v packer &>/dev/null; then
            log_info "Installing Packer..."
            $SUDO dnf install -y dnf-plugins-core
            $SUDO dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
            $SUDO dnf install -y packer
        fi
        ;;
    arch)
        $SUDO pacman -Syu --noconfirm \
            qemu-system-aarch64 \
            edk2-ovmf \
            cdrtools \
            ansible \
            sshpass \
            git \
            jq \
            curl \
            wget \
            packer
        ;;
    *)
        log_error "Unsupported OS: $OS"
        log_info "Please install manually: qemu-system-arm, qemu-efi-aarch64, packer, ansible, sshpass, genisoimage"
        exit 1
        ;;
esac

# Initialize git submodules (image-builder)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log_info "Initializing git submodules..."
cd "$PROJECT_DIR"
if [[ -f ".gitmodules" ]]; then
    git submodule update --init --recursive
    log_success "Git submodules initialized"
else
    log_warn ".gitmodules not found - submodules may need manual setup"
    log_info "Run: git submodule add https://github.com/kubernetes-sigs/image-builder.git local-build/image-builder"
fi

echo ""
log_info "Verifying installation..."

# Verify QEMU
if command -v qemu-system-aarch64 &>/dev/null; then
    QEMU_VERSION=$(qemu-system-aarch64 --version | head -1)
    log_success "QEMU: $QEMU_VERSION"
else
    log_error "qemu-system-aarch64 not found"
    exit 1
fi

# Verify EFI firmware
EFI_PATHS=(
    "/usr/share/AAVMF/AAVMF_CODE.fd"
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
    "/usr/share/edk2/aarch64/QEMU_EFI.fd"
)

EFI_FOUND=""
for path in "${EFI_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        EFI_FOUND="$path"
        break
    fi
done

if [[ -n "$EFI_FOUND" ]]; then
    log_success "EFI firmware: $EFI_FOUND"
else
    log_error "ARM64 EFI firmware not found"
    log_info "Searched paths: ${EFI_PATHS[*]}"
    exit 1
fi

# Verify Packer
if command -v packer &>/dev/null; then
    PACKER_VERSION=$(packer --version)
    log_success "Packer: $PACKER_VERSION"
else
    log_error "Packer not found"
    exit 1
fi

# Verify Ansible
if command -v ansible &>/dev/null; then
    ANSIBLE_VERSION=$(ansible --version | head -1)
    log_success "Ansible: $ANSIBLE_VERSION"
else
    log_error "Ansible not found"
    exit 1
fi

# Verify sshpass
if command -v sshpass &>/dev/null; then
    log_success "sshpass: installed"
else
    log_error "sshpass not found"
    exit 1
fi

# Verify genisoimage
if command -v genisoimage &>/dev/null; then
    log_success "genisoimage: installed"
else
    log_error "genisoimage not found"
    exit 1
fi

# Show system info
echo ""
log_info "System information:"
echo "  CPU cores: $(nproc)"
echo "  Memory: $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Architecture: $(uname -m)"

# Calculate recommended settings
TOTAL_THREADS=$(nproc)
QEMU_CPUS=$((TOTAL_THREADS - 2))
if [[ $QEMU_CPUS -lt 4 ]]; then QEMU_CPUS=4; fi
if [[ $QEMU_CPUS -gt 16 ]]; then QEMU_CPUS=16; fi
QEMU_MEMORY=$((QEMU_CPUS * 1024))

echo ""
log_info "Recommended QEMU settings for this system:"
echo "  Emulated ARM64 cores: $QEMU_CPUS"
echo "  VM memory: ${QEMU_MEMORY}MB"
echo "  TCG threads: $TOTAL_THREADS (multi-threaded)"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║                    Installation Complete                          ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
log_success "All dependencies installed successfully!"
echo ""
echo "  To build an ARM64 CAPI image locally:"
echo "    ./scripts/build-and-test.sh --local"
echo ""
echo "  To build with a specific Kubernetes version:"
echo "    ./scripts/build-and-test.sh --local --k8s-version v1.33.0"
echo ""
