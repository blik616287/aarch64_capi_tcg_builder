packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "kubernetes_semver" {
  type    = string
  default = "v1.32.4"
}

variable "kubernetes_series" {
  type    = string
  default = "v1.32"
}

variable "containerd_version" {
  type    = string
  default = "2.0.4"
}

variable "cni_version" {
  type    = string
  default = "1.6.0"
}

variable "crictl_version" {
  type    = string
  default = "1.32.0"
}

variable "runc_version" {
  type    = string
  default = "1.2.8"
}

variable "builder_password" {
  type      = string
  sensitive = true
}

variable "output_directory" {
  type    = string
  default = "output"
}

variable "image_name" {
  type    = string
  default = "ubuntu-2204-arm64-kube-v1.32.4"
}

variable "qemu_cpus" {
  type    = number
  default = 8
}

variable "qemu_memory" {
  type    = number
  default = 8192
}

variable "efi_firmware_code" {
  type    = string
  default = "/usr/share/AAVMF/AAVMF_CODE.fd"
}

variable "efi_firmware_vars" {
  type    = string
  default = "/usr/share/AAVMF/AAVMF_VARS.fd"
}

variable "image_builder_dir" {
  type    = string
  default = "image-builder"
}

variable "build_dir" {
  type    = string
  default = "."
}

# =============================================================================
# Source: QEMU with TCG emulation for ARM64 on x86
# =============================================================================

source "qemu" "capi-ubuntu-arm64-tcg" {
  iso_url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
  iso_checksum     = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  disk_image       = true
  disk_size        = "20G"
  format           = "qcow2"
  output_directory = var.output_directory
  vm_name          = var.image_name

  # TCG emulation settings for x86 host
  qemu_binary  = "qemu-system-aarch64"
  accelerator  = "tcg"
  machine_type = "virt"
  cpu_model    = "max"

  # Dynamic resource allocation
  memory = var.qemu_memory
  cpus   = var.qemu_cpus

  # EFI boot configuration
  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars

  # TCG performance optimization
  # Note: Multi-threaded TCG is enabled by default in recent QEMU versions
  qemuargs = [
    ["-cpu", "max"],
    ["-boot", "strict=off"],
    ["-smp", "${var.qemu_cpus},sockets=1,cores=${var.qemu_cpus},threads=1"],
    ["-global", "virtio-blk-device.physical_block_size=4096"]
  ]

  # Extended timeouts for emulation (3x normal)
  ssh_username           = "builder"
  ssh_password           = var.builder_password
  ssh_timeout            = "60m"
  ssh_handshake_attempts = 200

  cd_files = ["${var.build_dir}/cloud-init/user-data", "${var.build_dir}/cloud-init/meta-data"]
  cd_label = "cidata"

  shutdown_command = ""
  shutdown_timeout = "10m"

  headless = true
}

# =============================================================================
# Build
# =============================================================================

build {
  sources = ["source.qemu.capi-ubuntu-arm64-tcg"]

  # First boot setup
  provisioner "ansible" {
    user             = "builder"
    playbook_file    = "${var.image_builder_dir}/images/capi/ansible/firstboot.yml"
    use_proxy        = false
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_SSH_ARGS=-o PubkeyAuthentication=no -o PasswordAuthentication=yes",
      "ANSIBLE_TIMEOUT=120"
    ]
    extra_arguments = [
      "-e", "ansible_ssh_pass=${var.builder_password}",
      "-e", "ansible_ssh_common_args='-o PubkeyAuthentication=no -o PasswordAuthentication=yes'",
      "-e", "ubuntu_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "ubuntu_security_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "extra_debs=",
      "-e", "extra_repos=",
      "-e", "@${var.build_dir}/arm64-vars.json"
    ]
  }

  # Reboot after firstboot
  provisioner "shell" {
    inline            = ["sudo reboot"]
    expect_disconnect = true
  }

  provisioner "shell" {
    inline       = ["echo 'Reconnected after reboot'"]
    pause_before = "60s"
  }

  # Main node setup with Kubernetes
  provisioner "ansible" {
    user             = "builder"
    playbook_file    = "${var.image_builder_dir}/images/capi/ansible/node.yml"
    use_proxy        = false
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_SSH_ARGS=-o PubkeyAuthentication=no -o PasswordAuthentication=yes",
      "ANSIBLE_TIMEOUT=120"
    ]
    extra_arguments = [
      "-e", "ansible_ssh_pass=${var.builder_password}",
      "-e", "ansible_ssh_common_args='-o PubkeyAuthentication=no -o PasswordAuthentication=yes'",
      "-e", "@${var.build_dir}/arm64-vars.json",
      "-e", "ubuntu_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "ubuntu_security_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "extra_debs=",
      "-e", "extra_repos=",
      "-e", "kubernetes_semver=${var.kubernetes_semver}",
      "-e", "kubernetes_series=${var.kubernetes_series}",
      "-e", "kubernetes_cni_semver=v${var.cni_version}",
      "-e", "kubernetes_cni_source_type=http",
      "-e", "kubernetes_cni_http_source=https://github.com/containernetworking/plugins/releases/download",
      "-e", "kubernetes_source_type=http",
      "-e", "kubernetes_http_source=https://dl.k8s.io/release",
      "-e", "kubeadm_template=etc/kubeadm.yml",
      "-e", "kubernetes_container_registry=registry.k8s.io",
      "-e", "containerd_version=${var.containerd_version}",
      "-e", "containerd_url=https://github.com/containerd/containerd/releases/download/v${var.containerd_version}/containerd-${var.containerd_version}-linux-arm64.tar.gz",
      "-e", "containerd_sha256=",
      "-e", "containerd_service_url=https://raw.githubusercontent.com/containerd/containerd/refs/tags/v${var.containerd_version}/containerd.service",
      "-e", "containerd_wasm_shims_runtimes=",
      "-e", "containerd_additional_settings=",
      "-e", "containerd_cri_socket=/var/run/containerd/containerd.sock",
      "-e", "containerd_gvisor_runtime=false",
      "-e", "containerd_gvisor_version=latest",
      "-e", "crictl_url=https://github.com/kubernetes-sigs/cri-tools/releases/download/v${var.crictl_version}/crictl-v${var.crictl_version}-linux-arm64.tar.gz",
      "-e", "crictl_sha256=",
      "-e", "crictl_source_type=http",
      "-e", "runc_version=${var.runc_version}",
      "-e", "ecr_credential_provider=false",
      "-e", "node_custom_roles_post_sysprep=",
      "-e", "python_path="
    ]
  }
}
