#!/usr/bin/env bash
# build-local.sh — run the full or partial build pipeline locally.
# Optimised for Apple Silicon (M-series) Macs: native arm64, no QEMU for kernel.
#
# Usage:
#   ./scripts/build-local.sh kernel      # build + push kernel only
#   ./scripts/build-local.sh overlay     # build + push sbc-raspberrypi5 overlay only
#   ./scripts/build-local.sh extensions  # build + push sys-kernel-wifi extension only
#   ./scripts/build-local.sh image       # assemble final disk image only
#   ./scripts/build-local.sh all         # full pipeline in sequence (default)

set -euo pipefail

REGISTRY="ghcr.io"
REGISTRY_USERNAME="koorikla/talos-builder"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
  echo "Checking prerequisites..."

  if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install Docker Desktop: https://docs.docker.com/desktop/mac/install/"
    exit 1
  fi

  if ! docker buildx version &>/dev/null; then
    echo "ERROR: docker buildx not available. Update Docker Desktop."
    exit 1
  fi

  if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon not running. Start Docker Desktop."
    exit 1
  fi

  if ! docker pull --quiet ghcr.io/siderolabs/imager:v1.12.6 &>/dev/null; then
    echo "ERROR: Cannot pull from ghcr.io. Run: docker login ghcr.io"
    exit 1
  fi

  echo "Prerequisites OK."
}

# ── Kernel ────────────────────────────────────────────────────────────────────
build_kernel() {
  echo "==> Building kernel..."
  cd "${REPO_ROOT}"

  git config --global user.name "local-build" 2>/dev/null || true
  git config --global user.email "local@build" 2>/dev/null || true

  [[ -d checkouts/pkgs ]] || make checkouts
  make patches 2>/dev/null || make patches  # idempotent: ignore already-applied

  make kernel \
    REGISTRY="${REGISTRY}" \
    REGISTRY_USERNAME="${REGISTRY_USERNAME}" \
    PUSH=true \
    PLATFORM=linux/arm64

  echo "==> Kernel built and pushed."
}

# ── Overlay ───────────────────────────────────────────────────────────────────
build_overlay() {
  echo "==> Building sbc-raspberrypi5 overlay..."
  cd "${REPO_ROOT}"

  [[ -d checkouts/pkgs ]] || make checkouts
  make patches 2>/dev/null || true

  make overlay \
    REGISTRY="${REGISTRY}" \
    REGISTRY_USERNAME="${REGISTRY_USERNAME}" \
    PUSH=true \
    PLATFORM=linux/arm64

  echo "==> Overlay built and pushed."
}

# ── Extensions ────────────────────────────────────────────────────────────────
build_extensions() {
  echo "==> Building sys-kernel-wifi extension..."
  cd "${REPO_ROOT}"

  make extensions \
    REGISTRY="${REGISTRY}" \
    REGISTRY_USERNAME="${REGISTRY_USERNAME}"

  echo "==> Extension built and pushed."
}

# ── Image ─────────────────────────────────────────────────────────────────────
build_image() {
  echo "==> Assembling metal-arm64 image..."
  cd "${REPO_ROOT}"

  make image \
    REGISTRY="${REGISTRY}" \
    REGISTRY_USERNAME="${REGISTRY_USERNAME}"

  echo "==> Image written to _out/metal-arm64.raw.xz"
  ls -lh _out/
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
TARGET="${1:-all}"
check_prereqs

case "${TARGET}" in
  kernel)     build_kernel ;;
  overlay)    build_overlay ;;
  extensions) build_extensions ;;
  image)      build_image ;;
  all)
    build_kernel
    build_overlay
    build_extensions
    build_image
    ;;
  *)
    echo "Unknown target: ${TARGET}"
    echo "Usage: $0 [kernel|overlay|extensions|image|all]"
    exit 1
    ;;
esac
