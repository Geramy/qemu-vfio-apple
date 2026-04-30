#!/usr/bin/env bash
#
# Build a prebaked Ubuntu Desktop arm64 qcow2 artifact for apple-vfio.
#
# This first-pass pipeline starts from Ubuntu's official arm64 cloud image and
# provisions it into a desktop-oriented image under QEMU/HVF on macOS.
#
# Usage:
#   ./contrib/apple-vfio/image-builder/build-ubuntu-desktop-image.sh [output-dir]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

OUT_DIR="${1:-$REPO_ROOT/contrib/apple-vfio/image-builder/out/ubuntu-desktop-image}"
CACHE_DIR="$OUT_DIR/cache"
WORK_DIR="$OUT_DIR/work"
ARTIFACT_DIR="$OUT_DIR/artifacts"

IMAGE_NAME="${IMAGE_NAME:-ubuntu-desktop-resolute-arm64}"
BASE_IMAGE="${BASE_IMAGE:-resolute-server-cloudimg-arm64.img}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud-images.ubuntu.com/resolute/current/$BASE_IMAGE}"
DISK_SIZE="${DISK_SIZE:-96G}"
CPUS="${CPUS:-8}"
MEMORY="${MEMORY:-12G}"

BUILD_HOSTNAME="${BUILD_HOSTNAME:-ubuntu-resolute-desktop}"
BUILD_USER="${BUILD_USER:-ubuntu}"
BUILD_PASSWORD="${BUILD_PASSWORD:-ubuntu}"

INSTALL_FEX="${INSTALL_FEX:-1}"
INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_NVIDIA="${INSTALL_NVIDIA:-1}"
INSTALL_APPLE_DMA="${INSTALL_APPLE_DMA:-1}"

APPLE_DMA_SRC_DIR="${APPLE_DMA_SRC_DIR:-$REPO_ROOT/contrib/apple-dma/linux}"
APPLE_DMA_VERSION="${APPLE_DMA_VERSION:-0.1.0}"

QEMU_BIN="${QEMU_BIN:-}"
QEMU_IMG_BIN="${QEMU_IMG_BIN:-}"
QEMU_DATA_DIR="${QEMU_DATA_DIR:-}"
EFI_CODE_SRC="${EFI_CODE_SRC:-}"
EFI_VARS_SRC="${EFI_VARS_SRC:-}"

BASE_IMAGE_PATH="$CACHE_DIR/$BASE_IMAGE"
BUILD_DISK="$WORK_DIR/${IMAGE_NAME}.build.qcow2"
SEED_ISO="$WORK_DIR/${IMAGE_NAME}.seed.iso"
EFI_CODE_PATH="$WORK_DIR/edk2-aarch64-code.fd"
EFI_VARS_PATH="$WORK_DIR/edk2-aarch64-vars.fd"
BUILD_LOG="$WORK_DIR/${IMAGE_NAME}.build.log"
FINAL_IMAGE="$ARTIFACT_DIR/${IMAGE_NAME}.qcow2"
MANIFEST_PATH="$ARTIFACT_DIR/${IMAGE_NAME}.manifest.json"

pick_existing() {
    local candidate
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

log() {
    printf '[build-ubuntu-desktop-image] %s\n' "$*"
}

die() {
    printf '[build-ubuntu-desktop-image] error: %s\n' "$*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

ensure_inputs() {
    need_tool curl
    need_tool hdiutil
    need_tool python3
    need_tool shasum

    if [ -z "$QEMU_BIN" ]; then
        QEMU_BIN="$(pick_existing \
            "$REPO_ROOT/dist/qemu-system-aarch64" \
            "$REPO_ROOT/build/qemu-system-aarch64" \
        )" || die "qemu-system-aarch64 not found in dist/ or build/"
    fi

    if [ -z "$QEMU_IMG_BIN" ]; then
        QEMU_IMG_BIN="$(pick_existing \
            "$REPO_ROOT/dist/qemu-img" \
            "$REPO_ROOT/build/qemu-img" \
        )" || die "qemu-img not found in dist/ or build/"
    fi

    if [ -z "$QEMU_DATA_DIR" ]; then
        QEMU_DATA_DIR="$(pick_existing \
            "$REPO_ROOT/dist/share/qemu" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu" \
            "$REPO_ROOT/build/pc-bios" \
        )" || die "QEMU data directory not found; set QEMU_DATA_DIR explicitly"
    fi

    if [ -z "$EFI_CODE_SRC" ]; then
        EFI_CODE_SRC="$(pick_existing \
            "$REPO_ROOT/build/pc-bios/edk2-aarch64-code.fd" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu/edk2-aarch64-code.fd" \
            "$REPO_ROOT/dist/share/qemu/edk2-aarch64-code.fd" \
        )" || die "edk2-aarch64-code.fd not found; set EFI_CODE_SRC to a valid firmware blob"
    fi

    if [ -z "$EFI_VARS_SRC" ]; then
        EFI_VARS_SRC="$(pick_existing \
            "$REPO_ROOT/build/pc-bios/edk2-arm-vars.fd" \
            "$REPO_ROOT/build/pc-bios/edk2-aarch64-vars.fd" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu/edk2-arm-vars.fd" \
            "$REPO_ROOT/build/qemu-bundle/usr/local/share/qemu/edk2-aarch64-vars.fd" \
            "$REPO_ROOT/dist/share/qemu/edk2-arm-vars.fd" \
            "$REPO_ROOT/dist/share/qemu/edk2-aarch64-vars.fd" \
        )" || die "arm64 edk2 vars file not found; set EFI_VARS_SRC to a valid NVRAM template"
    fi
}

prepare_dirs() {
    mkdir -p "$CACHE_DIR" "$WORK_DIR" "$ARTIFACT_DIR"
}

download_base_image() {
    if [ -f "$BASE_IMAGE_PATH" ]; then
        log "using cached base image: $BASE_IMAGE_PATH"
        return
    fi

    log "downloading base image: $BASE_IMAGE_URL"
    curl -L --fail --continue-at - --progress-bar \
        -o "$BASE_IMAGE_PATH" "$BASE_IMAGE_URL"
}

prepare_build_disk() {
    rm -f "$BUILD_DISK"
    log "creating build disk: $BUILD_DISK"
    "$QEMU_IMG_BIN" create -f qcow2 \
        -b "$BASE_IMAGE_PATH" -F qcow2 \
        "$BUILD_DISK" "$DISK_SIZE" >/dev/null
}

prepare_firmware() {
    cp -f "$EFI_CODE_SRC" "$EFI_CODE_PATH"
    cp -f "$EFI_VARS_SRC" "$EFI_VARS_PATH"
}

render_seed_iso() {
    local seed_dir="$WORK_DIR/seed-files"
    local seed_output="$WORK_DIR/${IMAGE_NAME}.seed"
    rm -rf "$seed_dir"
    mkdir -p "$seed_dir"
    cp "$SCRIPT_DIR/cloud-init/meta-data" "$seed_dir/meta-data"

    local apple_dma_tgz="$WORK_DIR/apple-dma-src.tgz"
    log "tarring apple-dma source from $APPLE_DMA_SRC_DIR"
    tar -czf "$apple_dma_tgz" -C "$APPLE_DMA_SRC_DIR" \
        --exclude='*.o' --exclude='*.ko' --exclude='*.mod*' \
        --exclude='Module.symvers' --exclude='modules.order' \
        --exclude='.tmp_versions' --exclude='.*.cmd' \
        --exclude='test-kmod-build.sh' \
        .

    BUILD_HOSTNAME="$BUILD_HOSTNAME" \
    BUILD_USER="$BUILD_USER" \
    BUILD_PASSWORD="$BUILD_PASSWORD" \
    INSTALL_FEX="$INSTALL_FEX" \
    INSTALL_STEAM="$INSTALL_STEAM" \
    INSTALL_NVIDIA="$INSTALL_NVIDIA" \
    INSTALL_APPLE_DMA="$INSTALL_APPLE_DMA" \
    APPLE_DMA_VERSION="$APPLE_DMA_VERSION" \
    APPLE_DMA_TGZ="$apple_dma_tgz" \
    python3 - "$SCRIPT_DIR/cloud-init/user-data.template" \
        "$SCRIPT_DIR/guest/provision-desktop.sh" \
        "$seed_dir/user-data" <<'PY'
from pathlib import Path
import base64
import os
import sys

template = Path(sys.argv[1]).read_text()
guest = Path(sys.argv[2]).read_text().rstrip().splitlines()
indented_guest = "\n".join(
    ("      " + line) if line else "      "
    for line in guest
)

apple_dma_b64 = base64.b64encode(Path(os.environ["APPLE_DMA_TGZ"]).read_bytes()).decode("ascii")
apple_dma_lines = [apple_dma_b64[i : i + 76] for i in range(0, len(apple_dma_b64), 76)]
indented_apple_dma = "\n".join("      " + line for line in apple_dma_lines)

replacements = {
    "@@BUILD_HOSTNAME@@": os.environ["BUILD_HOSTNAME"],
    "@@BUILD_USER@@": os.environ["BUILD_USER"],
    "@@BUILD_PASSWORD@@": os.environ["BUILD_PASSWORD"],
    "@@INSTALL_FEX@@": os.environ["INSTALL_FEX"],
    "@@INSTALL_STEAM@@": os.environ["INSTALL_STEAM"],
    "@@INSTALL_NVIDIA@@": os.environ["INSTALL_NVIDIA"],
    "@@INSTALL_APPLE_DMA@@": os.environ["INSTALL_APPLE_DMA"],
    "@@APPLE_DMA_VERSION@@": os.environ["APPLE_DMA_VERSION"],
    "@@PROVISION_SCRIPT@@": indented_guest,
    "@@APPLE_DMA_SRC_B64@@": indented_apple_dma,
}

for old, new in replacements.items():
    template = template.replace(old, new)

Path(sys.argv[3]).write_text(template + "\n")
PY

    rm -rf "$SEED_ISO" "$seed_output" "$seed_output.iso" "$seed_output.cdr" \
        "$seed_output.iso.cdr"

    hdiutil makehybrid -iso -joliet -default-volume-name cidata \
        -o "$seed_output" "$seed_dir" >/dev/null

    if [ -f "$seed_output.iso" ]; then
        mv "$seed_output.iso" "$SEED_ISO"
    elif [ -f "$seed_output.cdr" ]; then
        mv "$seed_output.cdr" "$SEED_ISO"
    elif [ -f "$seed_output.iso.cdr" ]; then
        mv "$seed_output.iso.cdr" "$SEED_ISO"
    elif [ -f "$seed_output" ]; then
        mv "$seed_output" "$SEED_ISO"
    else
        die "failed to create cloud-init seed image"
    fi
}

run_builder_vm() {
    rm -f "$BUILD_LOG"
    log "booting builder VM"
    "$QEMU_BIN" \
        -L "$QEMU_DATA_DIR" \
        -accel hvf \
        -cpu host \
        -machine virt,highmem=on \
        -smp "$CPUS" \
        -m "$MEMORY" \
        -serial mon:stdio \
        -display none \
        -device virtio-rng-pci \
        -drive if=pflash,format=raw,readonly=on,file="$EFI_CODE_PATH" \
        -drive if=pflash,format=raw,file="$EFI_VARS_PATH" \
        -drive if=virtio,format=qcow2,file="$BUILD_DISK",discard=unmap,detect-zeroes=unmap \
        -drive if=virtio,format=raw,readonly=on,file="$SEED_ISO" \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        2>&1 | tee "$BUILD_LOG"
}

assert_success_log() {
    if ! grep -q "provisioning complete, powering off" "$BUILD_LOG"; then
        die "builder VM exited without the success marker; inspect $BUILD_LOG"
    fi
}

emit_artifact() {
    rm -f "$FINAL_IMAGE"
    log "flattening build disk into artifact"
    "$QEMU_IMG_BIN" convert -p -O qcow2 -c "$BUILD_DISK" "$FINAL_IMAGE"
}

write_manifest() {
    python3 - "$MANIFEST_PATH" <<'PY'
from pathlib import Path
import json
import os
import sys

manifest = {
    "name": os.environ["IMAGE_NAME"],
    "artifact": Path(os.environ["FINAL_IMAGE"]).name,
    "base_image": os.environ["BASE_IMAGE"],
    "base_image_url": os.environ["BASE_IMAGE_URL"],
    "disk_size": os.environ["DISK_SIZE"],
    "cpus": os.environ["CPUS"],
    "memory": os.environ["MEMORY"],
    "build_user": os.environ["BUILD_USER"],
    "features": {
        "desktop": True,
        "fex": os.environ["INSTALL_FEX"] == "1",
        "steam": os.environ["INSTALL_STEAM"] == "1",
        "nvidia": os.environ["INSTALL_NVIDIA"] == "1",
        "apple_dma": os.environ["INSTALL_APPLE_DMA"] == "1",
    },
    "sha256": os.environ["ARTIFACT_SHA256"],
    "size_bytes": int(os.environ["ARTIFACT_SIZE"]),
}

Path(sys.argv[1]).write_text(json.dumps(manifest, indent=2) + "\n")
PY
}

main() {
    ensure_inputs
    prepare_dirs
    download_base_image
    prepare_build_disk
    prepare_firmware
    render_seed_iso
    run_builder_vm
    assert_success_log
    emit_artifact

    ARTIFACT_SHA256="$(shasum -a 256 "$FINAL_IMAGE" | awk '{print $1}')"
    ARTIFACT_SIZE="$(stat -f '%z' "$FINAL_IMAGE")"
    export ARTIFACT_SHA256 ARTIFACT_SIZE
    export IMAGE_NAME FINAL_IMAGE BASE_IMAGE BASE_IMAGE_URL DISK_SIZE CPUS MEMORY
    export BUILD_USER INSTALL_FEX INSTALL_STEAM INSTALL_NVIDIA INSTALL_APPLE_DMA

    write_manifest

    log "artifact ready: $FINAL_IMAGE"
    log "manifest ready: $MANIFEST_PATH"
    log "build log: $BUILD_LOG"
}

main "$@"
