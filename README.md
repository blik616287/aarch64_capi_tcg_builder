# ARM64 CAPI Image Builder

Automated build system for creating ARM64 Cluster API (CAPI) images for Kubernetes deployment on NVIDIA Grace Hopper / DGX systems.

## Quick Start

```bash
# First-time setup (install QEMU, Packer, etc.)
make install-deps

# Build locally using QEMU TCG emulation
make build-local

# Run validation tests
make test

# Clean build artifacts
make clean
```

## Prerequisites

### Local Build
- **qemu-system-arm** and **qemu-efi-aarch64** for ARM64 emulation
- **Packer** >= 1.8
- **Ansible** >= 2.12
- **sshpass** for Packer SSH provisioning
- **genisoimage** for cloud-init ISO creation

Install all dependencies:
```bash
make install-deps
```

### Docker Build (Alternative)
- **Docker** installed and running

```bash
make build-local-docker
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Local Build (x86 host)                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Packer + QEMU TCG Emulation                            │    │
│  │  - Software translation (ARM64 on x86)                  │    │
│  │  - kubernetes-sigs/image-builder ansible playbooks      │    │
│  │  - Build time: ~30-60 minutes                           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                            │                                     │
│                            ▼                                     │
│  Output: ./output/                                               │
│  ├── ubuntu-2204-arm64-kube-v1.32.4.qcow2                       │
│  ├── ubuntu-2204-arm64-kube-v1.32.4.raw                         │
│  ├── ubuntu-2204-arm64-kube-v1.32.4.vmdk                        │
│  └── ubuntu-2204-arm64-kube-v1.32.4.ova                         │
└─────────────────────────────────────────────────────────────────┘
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make help` | Show available targets |
| `make install-deps` | Install build dependencies (QEMU, Packer, Ansible) |
| `make build-local` | Build using QEMU TCG emulation (~30-60 min) |
| `make build-local-docker` | Build inside Docker container (~30-60 min) |
| `make test` | Run image validation tests |
| `make clean` | Remove build artifacts |

### Custom Kubernetes Version

```bash
make build-local K8S_VERSION=v1.33.0
make build-local-docker K8S_VERSION=v1.33.0
```

## Configuration

### Environment Variables (Optional)

| Variable | Description | Default |
|----------|-------------|---------|
| `K8S_VERSION` | Kubernetes version | v1.32.4 |
| `CONTAINERD_VERSION` | containerd version | 2.0.4 |
| `CNI_VERSION` | CNI plugins version | 1.6.0 |
| `CRICTL_VERSION` | crictl version | 1.32.0 |

## Output Artifacts

| Format | Use Case | Size |
|--------|----------|------|
| **QCOW2** | KVM/QEMU, OpenStack | ~4 GB |
| **RAW** | Bare metal, dd to disk | 20 GB |
| **VMDK** | VMware | ~4 GB |
| **OVA** | VMware import | ~4 GB |

## Image Contents

- **Ubuntu 22.04 LTS** (Jammy) ARM64
- **Kubernetes v1.32.4** (kubeadm, kubectl, kubelet)
- **containerd v2.0.4**
- **CNI plugins v1.6.0**
- **crictl v1.32.0**
- Cloud-init enabled
- SSH server configured

## Testing the Image

### Boot with QEMU (on ARM64 host)

```bash
qemu-system-aarch64 \
  -machine virt,accel=kvm \
  -cpu host -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive file=output/ubuntu-2204-arm64-kube-v1.32.4.qcow2,format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

### Initialize Kubernetes

```bash
# Inside the VM
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Copy kubeconfig
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install CNI (e.g., Flannel)
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

## File Structure

```
.
├── Makefile                  # Build targets
├── README.md                 # This file
├── scripts/
│   ├── build-and-test.sh     # Main entry point
│   ├── build-local.sh        # Local QEMU TCG build
│   ├── build-local-docker.sh # Docker container build
│   ├── install-local-deps.sh # Dependency installer
│   ├── validate-image.sh     # Image validation tests
│   ├── convert-formats.sh    # Convert QCOW2 to RAW/VMDK/OVA
│   └── extract-pxe-files.sh  # Extract kernel/initrd for PXE
├── packer/
│   └── capi-arm64-local.pkr.hcl  # Packer build configuration
├── local-build/
│   ├── cloud-init/           # Cloud-init configuration
│   └── arm64-vars.json       # Ansible variable overrides
├── ansible/                  # Ansible playbooks and roles
├── files/                    # Patched Ansible tasks
└── output/                   # Build output directory
```

## Troubleshooting

### Build Fails with SSH Timeout

The image-builder ansible provisioner needs password auth:
- Ensure `sshpass` is installed: `apt install sshpass`
- Cloud-init must set up the builder user with password

### Image Won't Boot

Check EFI firmware paths:
```bash
ls /usr/share/AAVMF/AAVMF_CODE.fd
ls /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
```

### containerd Not Starting

Check the service:
```bash
systemctl status containerd
journalctl -u containerd
```

### QEMU Emulation Slow

TCG emulation is CPU-intensive. The build uses:
- `nproc - 2` cores (max 16, min 4)
- 1GB RAM per core

For faster builds, use an ARM64 host with native KVM.

## License

Internal use only.
