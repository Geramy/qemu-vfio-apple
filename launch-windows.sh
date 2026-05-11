#!/usr/bin/env bash
#
# Boot installed Windows 11 ARM with the AMD GPU passed through. Mirrors
# launch.sh exactly (same machine, RAM, ports, trace modes) so the resulting
# trace can be directly diffed against the Linux trace from the same hardware.
#
# Modes (same semantics as launch.sh):
#   ./launch-windows.sh           - performance: no tracing, no QMP
#   ./launch-windows.sh debug     - QMP open, events armed but disabled
#   ./launch-windows.sh trace     - tracing active from boot via trace-events.list
#
# Optional env:
#   TRACE_BAR_MMIO=1   forces vfio-apple-pci trace-bar-mmio=on (slower, captures
#                      every BAR MMIO).
#   WIN_DISK           override windows-arm.qcow2 path

set -euo pipefail
cd "$(dirname "$0")"

WIN_DISK="${WIN_DISK:-$(pwd)/windows-arm.qcow2}"
UEFI_VARS="$(pwd)/uefi-vars-windows.fd"
QMP_SOCK="$(pwd)/qmp.sock"
EVENTS_FILE="$(pwd)/trace-events.list"
mkdir -p "$(pwd)/traces"
TRACE_BIN_PREFIX="$(pwd)/traces/run-windows-$(date +%Y%m%d-%H%M%S)"
QEMU=./build/qemu-system-aarch64

if [ ! -f "$WIN_DISK" ]; then
  echo "ERROR: $WIN_DISK not found. Run ./launch-windows-install.sh first." >&2
  exit 1
fi

# Safety: refuse to boot if WIN_DISK happens to point at a Linux disk.
case "$(basename "$WIN_DISK")" in
  safety_overlay.qcow2|my_linux_ssd.qcow2)
    echo "ERROR: WIN_DISK is set to a Linux disk ($WIN_DISK). Refusing to launch." >&2
    exit 1
    ;;
esac
if [ ! -f "$UEFI_VARS" ]; then
  echo "ERROR: $UEFI_VARS not found. Run launch-windows-install.sh once first." >&2
  exit 1
fi
if ! command -v swtpm >/dev/null; then
  echo "ERROR: swtpm not installed. brew install swtpm" >&2
  exit 1
fi

MODE="${1:-perf}"

# Start swtpm in a per-launch socket directory; tear it down on exit.
TPM_DIR="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TPM_DIR"; rm -f "$QMP_SOCK"' EXIT
swtpm socket \
  --tpm2 \
  --tpmstate "dir=$TPM_DIR,mode=0600" \
  --ctrl "type=unixio,path=$TPM_DIR/swtpm-sock" \
  --log "level=20" \
  --terminate &
for _ in $(seq 1 50); do
  [ -S "$TPM_DIR/swtpm-sock" ] && break
  sleep 0.1
done

ARGS=(
  -machine virt,highmem=on,memory-backend=pc.ram
  -accel hvf,tso=on
  -cpu host
  -smp 4
  -m 48G
  -object memory-backend-ram,id=pc.ram,size=48G,prealloc=on,share=off
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
  -drive "if=pflash,format=raw,file=$UEFI_VARS"
  -device virtio-gpu-pci
  -display cocoa
  -device qemu-xhci,id=xhci
  -device usb-kbd,bus=xhci.0
  -device usb-tablet,bus=xhci.0
  -chardev "socket,id=chrtpm,path=$TPM_DIR/swtpm-sock"
  -tpmdev emulator,id=tpm0,chardev=chrtpm
  -device tpm-tis-device,tpmdev=tpm0
  -drive "if=none,id=hd0,file=$WIN_DISK,format=qcow2,cache=writeback,discard=unmap"
  -device virtio-blk-pci,drive=hd0,bootindex=1
  -netdev user,id=net0,hostfwd=tcp::2223-:3389
  -device virtio-net-pci,netdev=net0
)

case "$MODE" in
  perf|performance|"")
    echo "==> Performance mode (no tracing, no QMP)"
    ;;
  debug)
    echo "==> Debug mode (QMP at $QMP_SOCK, tracing armed but disabled)"
    rm -f "$QMP_SOCK"
    ARGS+=(-qmp "unix:${QMP_SOCK},server=on,wait=off" -trace "file=${TRACE_BIN_PREFIX}")
    ;;
  trace|tracing)
    if [ ! -f "$EVENTS_FILE" ]; then
      echo "ERROR: $EVENTS_FILE not found" >&2; exit 1
    fi
    echo "==> Trace mode (events from $EVENTS_FILE, QMP at $QMP_SOCK)"
    rm -f "$QMP_SOCK"
    ARGS+=(
      -qmp "unix:${QMP_SOCK},server=on,wait=off"
      -trace "events=${EVENTS_FILE},file=${TRACE_BIN_PREFIX}"
    )
    echo "    Trace file prefix: ${TRACE_BIN_PREFIX}-<pid>"
    ;;
  *)
    echo "Usage: $0 [perf|debug|trace]" >&2; exit 1
    ;;
esac

# Add GPU passthrough -- mirrors launch.sh's ordering.
if [ "${TRACE_BAR_MMIO:-0}" = "1" ]; then
  echo "    BAR mmap DISABLED (every MMIO traps; slower; SIMD accesses skipped)"
  ARGS+=(-device "vfio-apple-pci,host=05:00.0,dma-companion=on,trace-bar-mmio=on")
else
  ARGS+=(-device "vfio-apple-pci,host=05:00.0,dma-companion=on")
fi

echo "    GPU passthrough: 05:00.0 via vfio-apple-pci (dma-companion=on)"
echo "    RDP forwarded:   localhost:2223 -> windows:3389 (enable Remote Desktop inside Windows)"
echo ""

exec "$QEMU" "${ARGS[@]}"
