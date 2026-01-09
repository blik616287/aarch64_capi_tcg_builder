#!/bin/bash
#
# Convert QCOW2 image to multiple formats: Raw, VMDK, OVA
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/image-builder/output}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Find the latest QCOW2 image
find_qcow2_image() {
    local image
    image=$(ls -t "$OUTPUT_DIR"/*.qcow2 2>/dev/null | grep -v "latest" | head -1)

    if [ -z "$image" ]; then
        log_error "No QCOW2 image found in $OUTPUT_DIR"
        exit 1
    fi

    echo "$image"
}

convert_to_raw() {
    local input="$1"
    local output="${input%.qcow2}.raw"

    log_info "Converting to Raw format..."
    log_info "  Input:  $input"
    log_info "  Output: $output"

    qemu-img convert -f qcow2 -O raw -p "$input" "$output"

    log_info "✓ Raw image created: $(ls -lh "$output" | awk '{print $5}')"
    echo "$output"
}

convert_to_vmdk() {
    local input="$1"
    local output="${input%.qcow2}.vmdk"

    log_info "Converting to VMDK format..."
    log_info "  Input:  $input"
    log_info "  Output: $output"

    # Use streamOptimized for better VMware compatibility
    qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized -p "$input" "$output"

    log_info "✓ VMDK image created: $(ls -lh "$output" | awk '{print $5}')"
    echo "$output"
}

create_ovf() {
    local vmdk="$1"
    local base_name="${vmdk%.vmdk}"
    local ovf_file="${base_name}.ovf"

    log_info "Creating OVF manifest..."

    # Get VMDK file size
    local vmdk_size
    vmdk_size=$(stat -c %s "$vmdk")

    # Get virtual disk size (in bytes)
    local disk_size
    disk_size=$(qemu-img info "$vmdk" --output json | jq -r '.["virtual-size"]')

    # Create OVF descriptor
    cat > "$ovf_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vmw="http://www.vmware.com/schema/ovf"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="$(basename "$vmdk")" ovf:id="file1" ovf:size="$vmdk_size"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="$disk_size" ovf:capacityAllocationUnits="byte" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>Network information</Info>
    <Network ovf:name="VM Network">
      <Description>VM Network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="ubuntu-2204-arm64-capi">
    <Info>Ubuntu 22.04 ARM64 CAPI Image</Info>
    <Name>ubuntu-2204-arm64-capi</Name>
    <OperatingSystemSection ovf:id="100" vmw:osType="ubuntu64Guest">
      <Info>Ubuntu 22.04 ARM64</Info>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>ubuntu-2204-arm64-capi</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-19</vssd:VirtualSystemType>
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
        <rasd:ElementName>4096MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>4096</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:Parent>4</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>SCSI Controller 0</rasd:ElementName>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceSubType>VirtualSCSI</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>VM Network</rasd:Connection>
        <rasd:Description>Network adapter</rasd:Description>
        <rasd:ElementName>Network adapter 1</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>VmxNet3</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

    log_info "✓ OVF manifest created"
    echo "$ovf_file"
}

create_ova() {
    local vmdk="$1"
    local base_name="${vmdk%.vmdk}"
    local ovf_file="${base_name}.ovf"
    local ova_file="${base_name}.ova"
    local mf_file="${base_name}.mf"

    log_info "Creating OVA package..."

    # Create OVF if not exists
    if [ ! -f "$ovf_file" ]; then
        create_ovf "$vmdk"
    fi

    # Create manifest with SHA256 checksums
    log_info "  Computing checksums..."
    local ovf_sha256 vmdk_sha256
    ovf_sha256=$(sha256sum "$ovf_file" | awk '{print $1}')
    vmdk_sha256=$(sha256sum "$vmdk" | awk '{print $1}')

    cat > "$mf_file" << EOF
SHA256($(basename "$ovf_file"))= $ovf_sha256
SHA256($(basename "$vmdk"))= $vmdk_sha256
EOF

    # Create OVA (tar archive with specific order)
    log_info "  Packaging OVA..."
    cd "$(dirname "$vmdk")"
    tar -cvf "$(basename "$ova_file")" \
        "$(basename "$ovf_file")" \
        "$(basename "$vmdk")" \
        "$(basename "$mf_file")"

    log_info "✓ OVA package created: $(ls -lh "$ova_file" | awk '{print $5}')"

    # Cleanup intermediate files
    rm -f "$ovf_file" "$mf_file"

    echo "$ova_file"
}

print_checksums() {
    local base_name="$1"

    log_info "=========================================="
    log_info "File Checksums (SHA256)"
    log_info "=========================================="

    for ext in qcow2 raw vmdk ova; do
        local file="${base_name}.${ext}"
        if [ -f "$file" ]; then
            sha256sum "$file"
        fi
    done
}

main() {
    log_info "Image Format Converter"
    log_info "======================"

    # Check for qemu-img
    if ! command -v qemu-img &> /dev/null; then
        log_error "qemu-img not found. Install with: apt install qemu-utils"
        exit 1
    fi

    # Find source image
    local qcow2_image
    qcow2_image=$(find_qcow2_image)
    log_info "Source image: $qcow2_image"

    local base_name="${qcow2_image%.qcow2}"

    # Convert to all formats
    log_info ""
    convert_to_raw "$qcow2_image"

    log_info ""
    local vmdk_file
    vmdk_file=$(convert_to_vmdk "$qcow2_image")

    log_info ""
    create_ova "$vmdk_file"

    log_info ""
    print_checksums "$base_name"

    log_info ""
    log_info "=========================================="
    log_info "All formats generated successfully!"
    log_info "=========================================="
    log_info ""
    log_info "Files in $OUTPUT_DIR:"
    ls -lh "$OUTPUT_DIR"/*.{qcow2,raw,vmdk,ova} 2>/dev/null || true
}

main "$@"
