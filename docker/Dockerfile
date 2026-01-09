# ARM64 CAPI Image Builder - Docker Build Environment
#
# This Dockerfile creates a reproducible build environment for building
# ARM64 Kubernetes CAPI images on x86 hosts using QEMU TCG emulation.
#
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install all build dependencies (skip ansible, install via pip for newer version)
RUN apt-get update && apt-get install -y \
    qemu-system-arm \
    qemu-efi-aarch64 \
    qemu-utils \
    genisoimage \
    cloud-image-utils \
    python3-pip \
    sshpass \
    git \
    curl \
    wget \
    openssl \
    xorriso \
    unzip \
    kmod \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install Ansible via pip (need 2.11+ for 'split' filter)
RUN pip3 install --no-cache-dir ansible-core>=2.14

# Install Packer
ARG PACKER_VERSION=1.10.0
RUN curl -fsSL https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip -o /tmp/packer.zip \
    && unzip /tmp/packer.zip -d /usr/local/bin \
    && rm /tmp/packer.zip \
    && chmod +x /usr/local/bin/packer

# Create build user (matches host UID/GID via runtime args)
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} builder 2>/dev/null || true && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash builder 2>/dev/null || true && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

WORKDIR /build

# Copy build scripts and configs
COPY --chown=builder:builder scripts/ /build/scripts/
COPY --chown=builder:builder packer/ /build/packer/
COPY --chown=builder:builder files/ /build/files/

# Ensure scripts are executable
RUN chmod +x /build/scripts/*.sh

USER builder

# Install Ansible collections as builder user
RUN ansible-galaxy collection install community.general ansible.posix

ENTRYPOINT ["/build/scripts/build-local.sh"]
