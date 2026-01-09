# ARM64 CAPI Image Builder Makefile

.PHONY: build-local build-local-docker test clean clean-all help install-deps init-submodules

# Default Kubernetes version (can be overridden: make build-local K8S_VERSION=v1.33.0)
K8S_VERSION ?= v1.32.4

help:
	@echo "ARM64 CAPI Image Builder"
	@echo ""
	@echo "Usage:"
	@echo "  make install-deps       Install build dependencies and init submodules"
	@echo "  make init-submodules    Initialize git submodules only"
	@echo "  make build-local        Build locally using QEMU TCG emulation"
	@echo "  make build-local-docker Build inside Docker container"
	@echo "  make test               Run image validation tests"
	@echo "  make clean              Remove build artifacts (keeps submodules)"
	@echo "  make clean-all          Remove all artifacts including submodule state"
	@echo ""
	@echo "Options:"
	@echo "  K8S_VERSION=v1.33.0     Set Kubernetes version (default: v1.32.4)"
	@echo ""
	@echo "Examples:"
	@echo "  make install-deps       # First-time setup"
	@echo "  make build-local"
	@echo "  make build-local K8S_VERSION=v1.33.0"
	@echo "  make build-local-docker"
	@echo "  make test"
	@echo "  make clean"

init-submodules:
	@echo "Initializing git submodules..."
	git submodule update --init --recursive
	@echo "Submodules initialized"

install-deps: init-submodules
	./scripts/install-local-deps.sh

build-local:
	./scripts/build-and-test.sh --local --k8s-version $(K8S_VERSION) --skip-test

build-local-docker:
	./scripts/build-and-test.sh --local-docker --k8s-version $(K8S_VERSION) --skip-test

test:
	./scripts/validate-image.sh

clean:
	rm -rf output/*.qcow2 output/*.raw output/*.vmdk output/*.ova output/*.ovf
	rm -rf local-build/pxe-files/*
	rm -rf local-build/output/*
	rm -rf local-build/cloud-init
	rm -rf local-build/arm64-vars.json
	rm -rf local-build/efivars.fd
	rm -rf local-build/*.pkr.hcl
	rm -f build.log test.log
	@echo "Build artifacts cleaned (submodules preserved)"

clean-all: clean
	@echo "Resetting submodules..."
	git submodule deinit -f local-build/image-builder 2>/dev/null || true
	rm -rf .git/modules/local-build/image-builder 2>/dev/null || true
	rm -rf local-build/image-builder
	@echo "Full cleanup complete (run 'make init-submodules' to restore)"
