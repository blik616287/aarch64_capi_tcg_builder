#!/bin/bash
#
# Local Build Script - Build ARM64 CAPI images on x86 using QEMU TCG emulation
#
# This script builds ARM64 images locally without requiring AWS infrastructure.
# It uses QEMU's TCG (Tiny Code Generator) for software emulation with
# multi-threading support for improved performance.
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
K8S_VERSION="${K8S_VERSION:-v1.32.4}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
CNI_VERSION="${CNI_VERSION:-1.6.0}"
CRICTL_VERSION="${CRICTL_VERSION:-1.32.0}"
RUNC_VERSION="${RUNC_VERSION:-1.2.8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/local-build"
OUTPUT_DIR="$PROJECT_DIR/output"
PXE_DIR="$OUTPUT_DIR/pxe"
IMAGE_BUILDER_DIR="$BUILD_DIR/image-builder"
PACKER_TEMPLATE="$PROJECT_DIR/packer/capi-arm64-local.pkr.hcl"

# Derived values
K8S_SEMVER="${K8S_VERSION}"
K8S_SERIES="${K8S_VERSION%.*}"
IMAGE_NAME="ubuntu-2204-arm64-kube-${K8S_VERSION#v}"

# =============================================================================
# Colors and Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"; }

# =============================================================================
# Dynamic Resource Allocation
# =============================================================================
calculate_resources() {
    TOTAL_THREADS=$(nproc)
    QEMU_CPUS=$((TOTAL_THREADS - 2))

    # Ensure minimum of 4 and cap at 8 (QEMU virt machine limit)
    if [[ $QEMU_CPUS -lt 4 ]]; then
        QEMU_CPUS=4
    fi
    if [[ $QEMU_CPUS -gt 8 ]]; then
        QEMU_CPUS=8
    fi

    # Memory: 1GB per core, minimum 4GB
    QEMU_MEMORY=$((QEMU_CPUS * 1024))
    if [[ $QEMU_MEMORY -lt 4096 ]]; then
        QEMU_MEMORY=4096
    fi

    log_info "System: $TOTAL_THREADS threads available"
    log_info "Allocating: $QEMU_CPUS emulated ARM64 cores, ${QEMU_MEMORY}MB RAM"
    log_info "TCG will use all $TOTAL_THREADS host threads for translation"
}

# =============================================================================
# Find EFI Firmware
# =============================================================================
find_efi_firmware() {
    local paths=(
        "/usr/share/AAVMF/AAVMF_CODE.fd"
        "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
        "/usr/share/edk2/aarch64/QEMU_EFI.fd"
        "/usr/share/OVMF/AAVMF_CODE.fd"
    )

    for path in "${paths[@]}"; do
        if [[ -f "$path" ]]; then
            EFI_CODE="$path"
            # Find corresponding VARS file
            EFI_VARS="${path/CODE/VARS}"
            if [[ ! -f "$EFI_VARS" ]]; then
                EFI_VARS="${path%.fd}_VARS.fd"
            fi
            if [[ ! -f "$EFI_VARS" ]]; then
                EFI_VARS="$(dirname "$path")/QEMU_VARS.fd"
            fi
            if [[ ! -f "$EFI_VARS" ]]; then
                # Create a copy for writable vars
                EFI_VARS="$BUILD_DIR/efivars.fd"
                cp "$EFI_CODE" "$EFI_VARS"
            fi
            return 0
        fi
    done

    log_error "ARM64 EFI firmware not found"
    exit 1
}

# =============================================================================
# Setup Build Environment
# =============================================================================
setup_environment() {
    log_info "Setting up local build environment..."

    mkdir -p "$BUILD_DIR"

    # Find EFI firmware
    find_efi_firmware
    log_info "Using EFI firmware: $EFI_CODE"

    # Check for image-builder submodule
    if [[ ! -d "$IMAGE_BUILDER_DIR" ]] || [[ ! -f "$IMAGE_BUILDER_DIR/images/capi/ansible/node.yml" ]]; then
        log_info "Initializing image-builder submodule..."
        cd "$PROJECT_DIR"
        if [[ -f ".gitmodules" ]] && grep -q "image-builder" ".gitmodules"; then
            git submodule update --init --recursive local-build/image-builder
        else
            log_warn "image-builder submodule not configured, cloning directly..."
            git clone --depth 1 https://github.com/kubernetes-sigs/image-builder.git "$IMAGE_BUILDER_DIR"
        fi
        cd "$BUILD_DIR"
    fi

    log_success "Build environment ready"
}

# =============================================================================
# Create Build Files
# =============================================================================
create_build_files() {
    log_info "Creating build configuration files..."

    # Generate random password for builder user
    BUILDER_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # Create cloud-init directory and files
    mkdir -p "$BUILD_DIR/cloud-init"

    cat > "$BUILD_DIR/cloud-init/user-data" << CLOUDINIT_EOF
#cloud-config
users:
  - name: builder
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $BUILDER_PASSWORD
ssh_pwauth: true
runcmd:
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
CLOUDINIT_EOF

    cat > "$BUILD_DIR/cloud-init/meta-data" << METADATA_EOF
instance-id: capi-build-$(date +%s)
local-hostname: capi-builder
METADATA_EOF

    # Create ARM64 vars file to override x86-only packages
    cat > "$BUILD_DIR/arm64-vars.json" << VARS_EOF
{
  "common_virt_debs": [],
  "common_virt_rpms": [],
  "enable_hv_kvp_daemon": false,
  "auditd_enabled": false,
  "qemu_debs": ["cloud-init", "cloud-guest-utils", "cloud-initramfs-growroot"],
  "containerd_wasm_shims_runtimes": "",
  "sysusr_prefix": "/usr/local",
  "sysusrlocal_prefix": "/usr/local",
  "systemd_prefix": "/usr/lib/systemd",
  "pause_image": "registry.k8s.io/pause:3.10",
  "crictl_version": "$CRICTL_VERSION",
  "crictl_source_type": "http",
  "crictl_url": "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-arm64.tar.gz",
  "load_additional_components": false
}
VARS_EOF

    # Patch image-builder for ARM64 compatibility
    patch_image_builder

    log_success "Build configuration created"
}

# =============================================================================
# Patch Image Builder for ARM64
# =============================================================================
patch_image_builder() {
    log_info "Patching image-builder for ARM64 compatibility..."

    # Patch qemu.yml for ARM64
    local qemu_yml="$IMAGE_BUILDER_DIR/images/capi/ansible/roles/providers/tasks/qemu.yml"
    if [[ -f "$qemu_yml" ]] && ! grep -q "ignore_errors: true" "$qemu_yml"; then
        log_info "Patching qemu.yml..."
        cat > "$qemu_yml" << 'QEMU_YML_EOF'
- name: Install cloud-init packages
  ansible.builtin.apt:
    name: "{{ qemu_debs }}"
    state: present
  when: ansible_os_family == "Debian"

- name: Enable hv-kvp-daemon
  ansible.builtin.systemd:
    name: hv-kvp-daemon
    enabled: true
    state: started
  when:
    - ansible_os_family == "Debian"
    - enable_hv_kvp_daemon | default(false)
  ignore_errors: true
QEMU_YML_EOF
    fi

    # Patch kubernetes tasks to create bash-completion directory
    local k8s_main="$IMAGE_BUILDER_DIR/images/capi/ansible/roles/kubernetes/tasks/main.yml"
    if [[ -f "$k8s_main" ]] && ! grep -q "Create bash-completion directory" "$k8s_main"; then
        log_info "Patching kubernetes tasks.yml..."
        sed -i '/- name: Generate kubectl bash completion/i\
- name: Create bash-completion directory\
  ansible.builtin.file:\
    path: "{{ sysusr_prefix }}/share/bash-completion/completions"\
    state: directory\
    mode: "0755"\
' "$k8s_main"
    fi

    # Copy patched sysprep files if they exist
    local sysprep_dir="$IMAGE_BUILDER_DIR/images/capi/ansible/roles/sysprep"
    if [[ -f "$PROJECT_DIR/files/sysprep-main.yml" ]]; then
        log_info "Installing patched sysprep tasks..."
        cp "$PROJECT_DIR/files/sysprep-main.yml" "$sysprep_dir/tasks/main.yml"
    fi
    if [[ -f "$PROJECT_DIR/files/sysprep-handlers.yml" ]]; then
        log_info "Installing patched sysprep handlers..."
        cp "$PROJECT_DIR/files/sysprep-handlers.yml" "$sysprep_dir/handlers/main.yml"
    fi
}

# =============================================================================
# Run Packer Build
# =============================================================================
run_packer_build() {
    log_info "Starting Packer build with TCG emulation..."
    log_warn "This will take 30-60 minutes due to software emulation"

    cd "$BUILD_DIR"

    # Clean output directory contents (keep directory for Docker bind mounts)
    rm -rf "$OUTPUT_DIR"/* 2>/dev/null || true

    # Copy Packer template to build directory
    cp "$PACKER_TEMPLATE" "$BUILD_DIR/"

    # Initialize packer plugins
    packer init capi-arm64-local.pkr.hcl

    # Run build
    local start_time=$(date +%s)

    PACKER_LOG=1 packer build -force \
        -var "builder_password=$BUILDER_PASSWORD" \
        -var "kubernetes_semver=$K8S_SEMVER" \
        -var "kubernetes_series=$K8S_SERIES" \
        -var "containerd_version=$CONTAINERD_VERSION" \
        -var "cni_version=$CNI_VERSION" \
        -var "crictl_version=$CRICTL_VERSION" \
        -var "runc_version=$RUNC_VERSION" \
        -var "output_directory=$OUTPUT_DIR" \
        -var "image_name=$IMAGE_NAME" \
        -var "qemu_cpus=$QEMU_CPUS" \
        -var "qemu_memory=$QEMU_MEMORY" \
        -var "efi_firmware_code=$EFI_CODE" \
        -var "efi_firmware_vars=$EFI_VARS" \
        -var "image_builder_dir=$IMAGE_BUILDER_DIR" \
        -var "build_dir=$BUILD_DIR" \
        capi-arm64-local.pkr.hcl

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Packer build completed in ${duration}s ($((duration / 60))m $((duration % 60))s)"
}

# =============================================================================
# Convert Image Formats
# =============================================================================
convert_formats() {
    log_info "Converting image formats..."

    cd "$OUTPUT_DIR"
    local qcow2_file="$IMAGE_NAME"

    # Rename to .qcow2 extension if needed
    if [[ -f "$qcow2_file" ]] && [[ ! -f "${qcow2_file}.qcow2" ]]; then
        mv "$qcow2_file" "${qcow2_file}.qcow2"
    fi
    qcow2_file="${IMAGE_NAME}.qcow2"

    if [[ ! -f "$qcow2_file" ]]; then
        log_error "QCOW2 file not found: $qcow2_file"
        return 1
    fi

    # Convert to RAW
    log_info "Converting to RAW format..."
    qemu-img convert -f qcow2 -O raw "$qcow2_file" "${IMAGE_NAME}.raw"

    # Convert to VMDK
    log_info "Converting to VMDK format..."
    qemu-img convert -f qcow2 -O vmdk "$qcow2_file" "${IMAGE_NAME}.vmdk"

    # Create OVA
    log_info "Creating OVA package..."
    create_ova

    log_success "All format conversions completed"
}

create_ova() {
    cd "$OUTPUT_DIR"

    local vmdk_size=$(stat -c%s "${IMAGE_NAME}.vmdk")

    # Create OVF descriptor
    cat > "${IMAGE_NAME}.ovf" << OVF_EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="${IMAGE_NAME}.vmdk" ovf:id="file1" ovf:size="$vmdk_size"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="20" ovf:capacityAllocationUnits="byte * 2^30" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <VirtualSystem ovf:id="${IMAGE_NAME}">
    <Info>Ubuntu 22.04 ARM64 Kubernetes ${K8S_VERSION} CAPI Image</Info>
    <Name>${IMAGE_NAME}</Name>
    <OperatingSystemSection ovf:id="96">
      <Info>Ubuntu 64-bit ARM</Info>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${IMAGE_NAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-17</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>4 virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>4</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>8192MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>8192</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard Disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
OVF_EOF

    # Create manifest
    echo "SHA256(${IMAGE_NAME}.vmdk)= $(sha256sum ${IMAGE_NAME}.vmdk | awk '{print $1}')" > "${IMAGE_NAME}.mf"
    echo "SHA256(${IMAGE_NAME}.ovf)= $(sha256sum ${IMAGE_NAME}.ovf | awk '{print $1}')" >> "${IMAGE_NAME}.mf"

    # Create OVA (tar archive)
    tar -cvf "${IMAGE_NAME}.ova" "${IMAGE_NAME}.ovf" "${IMAGE_NAME}.vmdk" "${IMAGE_NAME}.mf"

    # Cleanup intermediate files
    rm -f "${IMAGE_NAME}.ovf" "${IMAGE_NAME}.mf"
}

# =============================================================================
# Extract PXE Boot Files
# =============================================================================
extract_pxe_files() {
    log_info "Extracting PXE boot files..."

    cd "$OUTPUT_DIR"
    local qcow2_file="${IMAGE_NAME}.qcow2"

    if [[ ! -f "$qcow2_file" ]]; then
        log_warn "QCOW2 file not found, skipping PXE extraction"
        return 0
    fi

    mkdir -p "$PXE_DIR"

    # Load NBD module
    if ! lsmod | grep -q nbd; then
        sudo modprobe nbd max_part=8
    fi

    # Find available NBD device
    local nbd_dev=""
    for i in {0..15}; do
        if [[ ! -e /sys/block/nbd$i/pid ]] || [[ ! -s /sys/block/nbd$i/pid ]]; then
            nbd_dev="/dev/nbd$i"
            break
        fi
    done

    if [[ -z "$nbd_dev" ]]; then
        log_warn "No available NBD device, skipping PXE extraction"
        return 0
    fi

    # Connect QCOW2 to NBD
    sudo qemu-nbd --connect="$nbd_dev" "$qcow2_file"
    sleep 2

    # Wait for partition to appear
    local partition="${nbd_dev}p1"
    local waited=0
    while [[ ! -b "$partition" ]] && [[ $waited -lt 10 ]]; do
        sleep 1
        ((waited++))
    done

    if [[ ! -b "$partition" ]]; then
        sudo partprobe "$nbd_dev" 2>/dev/null || true
        sleep 2
    fi

    # Mount and extract
    sudo mkdir -p /mnt/capi-boot
    if sudo mount "$partition" /mnt/capi-boot 2>/dev/null; then
        sudo cp /mnt/capi-boot/boot/vmlinuz* "$PXE_DIR/" 2>/dev/null || \
            sudo cp /mnt/capi-boot/vmlinuz* "$PXE_DIR/" 2>/dev/null || true
        sudo cp /mnt/capi-boot/boot/initrd* "$PXE_DIR/" 2>/dev/null || \
            sudo cp /mnt/capi-boot/initrd* "$PXE_DIR/" 2>/dev/null || true

        sudo chmod 644 "$PXE_DIR"/* 2>/dev/null || true
        sudo chown "$(id -u):$(id -g)" "$PXE_DIR"/* 2>/dev/null || true

        sudo umount /mnt/capi-boot
        log_success "PXE files extracted"
    else
        log_warn "Could not mount partition for PXE extraction"
    fi

    sudo qemu-nbd --disconnect "$nbd_dev"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     ARM64 CAPI Image Build - Local x86 TCG Emulation              ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Kubernetes: $K8S_VERSION"
    echo "  containerd: $CONTAINERD_VERSION"
    echo "  CNI:        $CNI_VERSION"
    echo "  crictl:     $CRICTL_VERSION"
    echo ""

    local start_time=$(date +%s)

    # Calculate optimal resource allocation
    calculate_resources

    setup_environment
    create_build_files
    run_packer_build
    convert_formats
    extract_pxe_files

    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                     BUILD COMPLETE                                ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Total time: ${total_duration}s ($((total_duration / 60))m $((total_duration % 60))s)"
    echo ""
    echo "  Output files:"
    ls -lh "$OUTPUT_DIR"/*.{qcow2,raw,vmdk,ova} 2>/dev/null || ls -lh "$OUTPUT_DIR"
    echo ""
    if [[ -d "$PXE_DIR" ]] && ls "$PXE_DIR"/* &>/dev/null; then
        echo "  PXE files:"
        ls -lh "$PXE_DIR"
        echo ""
    fi
}

main "$@"
