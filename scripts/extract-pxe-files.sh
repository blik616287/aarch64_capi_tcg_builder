#!/bin/bash
#
# Extract kernel and initrd from CAPI image for PXE boot
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/image-builder/output}"
PXE_DIR="${PXE_DIR:-$OUTPUT_DIR/pxe}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    log_info "Cleaning up..."

    # Unmount if mounted
    if mountpoint -q /mnt/capi-image 2>/dev/null; then
        sudo umount /mnt/capi-image
    fi

    # Disconnect NBD if connected
    if [ -e /dev/nbd0p1 ]; then
        sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    fi

    # Remove mount point
    sudo rmdir /mnt/capi-image 2>/dev/null || true
}

trap cleanup EXIT

find_image() {
    local image

    # Prefer QCOW2 for NBD mounting
    image=$(ls -t "$OUTPUT_DIR"/*.qcow2 2>/dev/null | grep -v "latest" | head -1 || true)

    if [ -z "$image" ]; then
        log_error "No QCOW2 image found in $OUTPUT_DIR"
        exit 1
    fi

    echo "$image"
}

setup_nbd() {
    log_info "Setting up NBD module..."

    # Load NBD module
    if ! lsmod | grep -q nbd; then
        sudo modprobe nbd max_part=8
    fi

    # Wait for module to load
    sleep 1

    if [ ! -e /dev/nbd0 ]; then
        log_error "NBD device /dev/nbd0 not found"
        exit 1
    fi

    log_info "✓ NBD module loaded"
}

mount_image() {
    local image="$1"

    log_info "Mounting image: $image"

    # Connect image to NBD device
    sudo qemu-nbd --connect=/dev/nbd0 "$image"

    # Wait for partitions to appear
    sleep 2
    sudo partprobe /dev/nbd0
    sleep 1

    # Find the boot partition (usually partition 1 or 15 for EFI)
    local boot_part=""

    # Check for EFI partition (type ef00)
    if [ -e /dev/nbd0p15 ]; then
        boot_part="/dev/nbd0p15"
    elif [ -e /dev/nbd0p1 ]; then
        boot_part="/dev/nbd0p1"
    else
        log_error "No partition found on image"
        sudo fdisk -l /dev/nbd0
        exit 1
    fi

    log_info "  Boot partition: $boot_part"

    # Create mount point
    sudo mkdir -p /mnt/capi-image

    # Mount the root partition (usually p1 for cloud images)
    if [ -e /dev/nbd0p1 ]; then
        sudo mount /dev/nbd0p1 /mnt/capi-image
        log_info "✓ Image mounted at /mnt/capi-image"
    else
        log_error "Could not find root partition"
        exit 1
    fi
}

extract_files() {
    log_info "Extracting kernel and initrd..."

    # Create PXE output directory
    mkdir -p "$PXE_DIR"

    # Find and copy kernel
    local kernel
    kernel=$(ls /mnt/capi-image/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)

    if [ -n "$kernel" ] && [ -f "$kernel" ]; then
        sudo cp "$kernel" "$PXE_DIR/vmlinuz-arm64"
        sudo chown "$(whoami):$(whoami)" "$PXE_DIR/vmlinuz-arm64"
        log_info "✓ Kernel: $(ls -lh "$PXE_DIR/vmlinuz-arm64" | awk '{print $5}')"
    else
        log_error "Kernel not found in /mnt/capi-image/boot/"
        ls -la /mnt/capi-image/boot/ || true
        exit 1
    fi

    # Find and copy initrd
    local initrd
    initrd=$(ls /mnt/capi-image/boot/initrd.img-* 2>/dev/null | sort -V | tail -1 || true)

    if [ -n "$initrd" ] && [ -f "$initrd" ]; then
        sudo cp "$initrd" "$PXE_DIR/initrd-arm64.img"
        sudo chown "$(whoami):$(whoami)" "$PXE_DIR/initrd-arm64.img"
        log_info "✓ Initrd: $(ls -lh "$PXE_DIR/initrd-arm64.img" | awk '{print $5}')"
    else
        log_error "Initrd not found in /mnt/capi-image/boot/"
        exit 1
    fi

    # Copy kernel config if exists
    local config
    config=$(ls /mnt/capi-image/boot/config-* 2>/dev/null | sort -V | tail -1 || true)

    if [ -n "$config" ] && [ -f "$config" ]; then
        sudo cp "$config" "$PXE_DIR/config-arm64"
        sudo chown "$(whoami):$(whoami)" "$PXE_DIR/config-arm64"
        log_info "✓ Config: config-arm64"
    fi
}

print_summary() {
    log_info ""
    log_info "=========================================="
    log_info "PXE Files Extracted"
    log_info "=========================================="
    log_info ""
    log_info "Output directory: $PXE_DIR"
    log_info ""
    log_info "Files:"
    ls -lh "$PXE_DIR"/
    log_info ""
    log_info "Next steps:"
    log_info "  1. Upload to S3: ./upload-to-s3.sh"
    log_info "  2. Copy to PXE server's /var/lib/tftpboot/"
    log_info "  3. Update GRUB config with correct paths"
}

main() {
    log_info "PXE File Extractor"
    log_info "=================="

    # Check prerequisites
    if ! command -v qemu-nbd &> /dev/null; then
        log_error "qemu-nbd not found. Install with: apt install qemu-utils"
        exit 1
    fi

    # Find image
    local image
    image=$(find_image)
    log_info "Source image: $image"

    # Setup and mount
    setup_nbd
    mount_image "$image"

    # Extract files
    extract_files

    # Cleanup happens via trap

    print_summary
}

main "$@"
