#!/bin/bash
#
# Image Validation Script
#
# This script validates the built CAPI image by:
#   - Checking image files exist
#   - Validating image format
#   - Booting the image in a VM (ARM64 hosts only)
#   - Verifying ARM64 architecture
#   - Checking Kubernetes components
#   - Testing containerd runtime
#   - Validating nested virtualization support
#
# On x86 hosts, only static validation is performed (no VM boot tests)
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Support both local and remote build directories
if [[ -d "/opt/capi-build/output" ]]; then
    BUILD_DIR="/opt/capi-build"
    OUTPUT_DIR="$BUILD_DIR/output"
else
    BUILD_DIR="$PROJECT_DIR"
    OUTPUT_DIR="$PROJECT_DIR/output"
fi

TEST_DIR="/tmp/capi-test"
VM_PORT=$((2200 + RANDOM % 100))

# Find the QCOW2 image
QCOW2_IMAGE=$(ls "$OUTPUT_DIR"/*.qcow2 2>/dev/null | head -1 || echo "")

# Detect host architecture
HOST_ARCH=$(uname -m)

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# =============================================================================
# Helper Functions
# =============================================================================
log_info() { echo "[INFO] $1"; }
log_test() { echo "[TEST] $1"; }
log_pass() { echo "[PASS] $1"; ((TESTS_PASSED++)); }
log_fail() { echo "[FAIL] $1"; ((TESTS_FAILED++)); FAILED_TESTS+=("$1"); }
log_skip() { echo "[SKIP] $1"; }

cleanup() {
    log_info "Cleaning up..."
    # Kill any running QEMU processes for our test
    pkill -f "qemu-system.*capi-test-vm" 2>/dev/null || true
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

can_run_arm64_vm() {
    # Check if we can run ARM64 VMs with KVM
    if [[ "$HOST_ARCH" == "aarch64" ]] && [[ -e /dev/kvm ]]; then
        return 0
    fi
    return 1
}

# =============================================================================
# Tests
# =============================================================================
test_image_exists() {
    log_test "Checking image files exist..."

    if [[ -f "$QCOW2_IMAGE" ]]; then
        log_pass "QCOW2 image exists: $(basename "$QCOW2_IMAGE")"
    else
        log_fail "QCOW2 image not found"
        return 1
    fi

    # Other formats are optional - just report status
    local raw_image="${QCOW2_IMAGE%.qcow2}.raw"
    local vmdk_image="${QCOW2_IMAGE%.qcow2}.vmdk"
    local ova_image="${QCOW2_IMAGE%.qcow2}.ova"

    if [[ -f "$raw_image" ]]; then
        log_pass "RAW image exists"
    else
        log_info "RAW image not present (optional)"
    fi

    if [[ -f "$vmdk_image" ]]; then
        log_pass "VMDK image exists"
    else
        log_info "VMDK image not present (optional)"
    fi

    if [[ -f "$ova_image" ]]; then
        log_pass "OVA image exists"
    else
        log_info "OVA image not present (optional)"
    fi
}

test_image_format() {
    log_test "Validating image format..."

    local format
    format=$(qemu-img info "$QCOW2_IMAGE" | grep "file format" | awk '{print $3}')

    if [[ "$format" == "qcow2" ]]; then
        log_pass "Image format is QCOW2"
    else
        log_fail "Image format is not QCOW2: $format"
    fi

    local size
    size=$(qemu-img info "$QCOW2_IMAGE" | grep "virtual size" | awk '{print $3}')
    log_info "Virtual size: $size"
}

test_pxe_files() {
    log_test "Checking PXE boot files..."

    local pxe_dir="$BUILD_DIR/pxe-files"

    # Also check local-build pxe directory
    if [[ ! -d "$pxe_dir" ]] && [[ -d "$PROJECT_DIR/local-build/pxe-files" ]]; then
        pxe_dir="$PROJECT_DIR/local-build/pxe-files"
    fi

    if [[ ! -d "$pxe_dir" ]]; then
        log_info "PXE files directory not found (may not be extracted yet)"
        return 0
    fi

    if ls "$pxe_dir"/vmlinuz* &>/dev/null; then
        log_pass "Kernel (vmlinuz) found"
    else
        log_fail "Kernel (vmlinuz) not found"
    fi

    if ls "$pxe_dir"/initrd* &>/dev/null; then
        log_pass "Initrd found"
    else
        log_fail "Initrd not found"
    fi
}

test_boot_vm() {
    log_test "Booting VM from image..."

    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    # Create a copy of the image for testing
    cp "$QCOW2_IMAGE" ./test-image.qcow2

    # Create cloud-init for test VM
    mkdir -p cloud-init

    cat > cloud-init/user-data << 'EOF'
#cloud-config
hostname: capi-test
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ubuntu
ssh_pwauth: true
EOF

    cat > cloud-init/meta-data << EOF
instance-id: capi-test-$(date +%s)
local-hostname: capi-test
EOF

    # Create cloud-init ISO
    genisoimage -output cloud-init.iso -volid cidata -joliet -rock \
        cloud-init/user-data cloud-init/meta-data 2>/dev/null

    # Find EFI firmware
    local efi_code=""
    local efi_vars=""
    for path in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
        if [[ -f "$path" ]]; then
            efi_code="$path"
            break
        fi
    done

    for path in /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/qemu-efi-aarch64/vars-template-pflash.raw; do
        if [[ -f "$path" ]]; then
            efi_vars="$path"
            break
        fi
    done

    if [[ -z "$efi_code" ]]; then
        log_fail "EFI firmware not found"
        return 1
    fi

    # Copy EFI vars if available
    if [[ -n "$efi_vars" ]]; then
        cp "$efi_vars" ./efivars.fd
    else
        # Create empty vars file
        truncate -s 64M ./efivars.fd
    fi

    # Start VM in background
    log_info "Starting test VM (this takes ~60 seconds)..."

    nohup qemu-system-aarch64 \
        -name capi-test-vm \
        -machine virt,accel=kvm \
        -cpu host \
        -m 4096 \
        -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="$efi_code" \
        -drive if=pflash,format=raw,file=./efivars.fd \
        -drive file=test-image.qcow2,format=qcow2,if=virtio \
        -drive file=cloud-init.iso,format=raw,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::${VM_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        > vm.log 2>&1 &

    VM_PID=$!
    log_info "VM started with PID $VM_PID"

    # Wait for VM to boot
    local max_wait=120
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
               -p $VM_PORT ubuntu@localhost "echo 'SSH ready'" 2>/dev/null; then
            log_pass "VM booted and SSH accessible"
            return 0
        fi
        sleep 5
        ((waited += 5))
        echo -n "."
    done

    echo ""
    log_fail "VM failed to boot within ${max_wait}s"
    log_info "VM log tail:"
    tail -30 vm.log
    return 1
}

run_vm_command() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $VM_PORT ubuntu@localhost "$@" 2>/dev/null
}

test_architecture() {
    log_test "Verifying ARM64 architecture..."

    local arch
    arch=$(run_vm_command "uname -m")

    if [[ "$arch" == "aarch64" ]]; then
        log_pass "Architecture is aarch64 (ARM64)"
    else
        log_fail "Architecture is not ARM64: $arch"
    fi

    local dpkg_arch
    dpkg_arch=$(run_vm_command "dpkg --print-architecture")

    if [[ "$dpkg_arch" == "arm64" ]]; then
        log_pass "dpkg architecture is arm64"
    else
        log_fail "dpkg architecture is not arm64: $dpkg_arch"
    fi
}

test_kubernetes_binaries() {
    log_test "Checking Kubernetes binaries..."

    # kubeadm
    if run_vm_command "which kubeadm" &>/dev/null; then
        local kubeadm_version
        kubeadm_version=$(run_vm_command "kubeadm version -o short")
        log_pass "kubeadm installed: $kubeadm_version"
    else
        log_fail "kubeadm not found"
    fi

    # kubectl
    if run_vm_command "which kubectl" &>/dev/null; then
        local kubectl_version
        kubectl_version=$(run_vm_command "kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 | awk '{print \$2}'")
        log_pass "kubectl installed: $kubectl_version"
    else
        log_fail "kubectl not found"
    fi

    # kubelet
    if run_vm_command "which kubelet" &>/dev/null; then
        log_pass "kubelet installed"
    else
        log_fail "kubelet not found"
    fi

    # Binary architecture check
    local kubeadm_arch
    kubeadm_arch=$(run_vm_command "file /usr/bin/kubeadm | grep -o 'ARM aarch64'")
    if [[ -n "$kubeadm_arch" ]]; then
        log_pass "kubeadm binary is ARM64"
    else
        log_fail "kubeadm binary is not ARM64"
    fi
}

test_containerd() {
    log_test "Checking containerd..."

    # Check if running
    if run_vm_command "systemctl is-active containerd" | grep -q "active"; then
        log_pass "containerd service is running"
    else
        log_fail "containerd service is not running"
    fi

    # Check version
    local containerd_version
    containerd_version=$(run_vm_command "/usr/local/bin/containerd --version 2>/dev/null | awk '{print \$3}'")
    if [[ -n "$containerd_version" ]]; then
        log_pass "containerd version: $containerd_version"
    else
        log_fail "Could not get containerd version"
    fi

    # Check crictl
    if run_vm_command "which crictl" &>/dev/null; then
        log_pass "crictl installed"
    else
        log_fail "crictl not found"
    fi
}

test_cni_plugins() {
    log_test "Checking CNI plugins..."

    local cni_count
    cni_count=$(run_vm_command "ls /opt/cni/bin/ 2>/dev/null | wc -l")

    if [[ "$cni_count" -gt 5 ]]; then
        log_pass "CNI plugins installed ($cni_count plugins)"
    else
        log_fail "CNI plugins missing or incomplete"
    fi

    # Check for essential plugins
    for plugin in bridge loopback host-local; do
        if run_vm_command "test -f /opt/cni/bin/$plugin"; then
            log_pass "CNI plugin '$plugin' present"
        else
            log_fail "CNI plugin '$plugin' missing"
        fi
    done
}

test_kubeadm_preflight() {
    log_test "Running kubeadm preflight checks..."

    local preflight_output
    preflight_output=$(run_vm_command "sudo kubeadm init --dry-run 2>&1" || true)

    if echo "$preflight_output" | grep -q "Your Kubernetes control-plane has initialized"; then
        log_pass "kubeadm preflight checks passed (dry-run)"
    elif echo "$preflight_output" | grep -qi "error"; then
        log_info "kubeadm dry-run output:"
        echo "$preflight_output" | tail -20
        log_fail "kubeadm preflight has errors"
    else
        log_pass "kubeadm preflight checks completed"
    fi
}

test_nested_virtualization() {
    log_test "Checking nested virtualization support..."

    if run_vm_command "test -e /dev/kvm"; then
        log_pass "/dev/kvm exists (nested virt available)"
    else
        log_info "/dev/kvm not present (nested virt may not be enabled)"
        # This is not a failure - depends on host configuration
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           ARM64 CAPI Image Validation                             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Host architecture: $HOST_ARCH"
    log_info "Output directory: $OUTPUT_DIR"

    if [[ -z "$QCOW2_IMAGE" ]]; then
        log_fail "No QCOW2 image found in $OUTPUT_DIR"
        exit 1
    fi

    log_info "Testing image: $(basename "$QCOW2_IMAGE")"
    echo ""

    # Static tests (no VM needed)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Static Validation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    test_image_exists || true
    test_image_format || true
    test_pxe_files || true

    # Boot VM and run dynamic tests (ARM64 hosts with KVM only)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Dynamic Validation (VM Boot)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if can_run_arm64_vm; then
        if test_boot_vm; then
            echo ""
            test_architecture || true
            test_kubernetes_binaries || true
            test_containerd || true
            test_cni_plugins || true
            test_kubeadm_preflight || true
            test_nested_virtualization || true
        fi
    else
        log_skip "VM boot tests skipped (requires ARM64 host with KVM)"
        log_info "To run full validation, test on an ARM64 system"
    fi

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Passed: $TESTS_PASSED"
    echo "  Failed: $TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "  Failed tests:"
        for test in "${FAILED_TESTS[@]}"; do
            echo "    - $test"
        done
        echo ""
        exit 1
    else
        echo "  All tests passed!"
        echo ""
        exit 0
    fi
}

main "$@"
