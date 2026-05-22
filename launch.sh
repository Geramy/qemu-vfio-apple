#!/usr/bin/env bash
#
# QEMU launch script with three modes:
#   ./launch.sh              - performance: no tracing, no QMP, lowest overhead
#   ./launch.sh debug        - QMP socket open; tracing armed but disabled.
#                              Use ./trace-control.sh on|off|<event_glob> to
#                              toggle events at runtime.
#   ./launch.sh trace        - tracing active from boot via events file.
#                              Writes binary trace to ./trace-<pid>.bin and
#                              opens QMP for runtime toggling.
#
# Trace data is emitted by the "simple" backend (binary). Convert with
#   ./trace-to-text.sh trace-<pid>.bin > trace.txt
# Open trace.txt in TraceCompass via Custom Text Trace parser.

set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-perf}"
QMP_SOCK="$(pwd)/qmp.sock"
EVENTS_FILE="$(pwd)/trace-events.list"
# IMPORTANT: do not use $(pwd)/trace -- that collides with the QEMU source
# directory ./trace/ and QEMU silently drops all trace data. Use a dedicated
# subdir under ./traces/.
mkdir -p "$(pwd)/traces"
TRACE_BIN_PREFIX="$(pwd)/traces/run-$(date +%Y%m%d-%H%M%S)"

QEMU=./build/qemu-system-aarch64

# Base QEMU args. IMPORTANT: device ordering and memory size match the
# previously-known-good manual invocation. Putting vfio-apple-pci *after* the
# virtio-net device gives the GPU guest PCI slot 00:05.0, which is what the
# amdgpu+SMU firmware load path was last seen working with. Reordering can
# move the GPU to 00:04.0 and break SMU init at boot.
ARGS=(
  -machine virt,highmem=on,memory-backend=pc.ram
  -accel hvf,tso=on
  -cpu host
  -smp 8
  -m 48G
  -object memory-backend-ram,id=pc.ram,size=48G,prealloc=on,share=off
  -device virtio-gpu-pci
  -display cocoa
  -device virtio-keyboard-pci
  -device virtio-tablet-pci
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
  -drive if=virtio,format=qcow2,file=./safety_overlay.qcow2
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  -device virtio-net-pci,netdev=net0
)

# GPU passthrough device.
#
# NO_GPU=1 skips the GPU passthrough device entirely. Use this when you need to
# boot the guest (e.g. to build a kernel patch) without risking putting the GPU
# into a bad state on a failed init attempt.
#
# trace-bar-mmio=on (TRACE_BAR_MMIO=1) disables BAR mmap so every guest BAR
# access traps to QEMU and fires apple_vfio_bar_{read,write} trace events.
# Big perf hit, and some NEON/SIMD/atomic accesses cannot be emulated (the
# patched HVF logs a warning and silently skips those -- the device sees
# nothing for that instruction). Useful for capturing PSP/SMU register
# sequences leading up to a hang. Pair with in-guest ftrace (guest-trace-amdgpu.sh)
# for the data the host-side trace can't show.
if [ "${NO_GPU:-0}" = "1" ]; then
  echo "    GPU passthrough SKIPPED (NO_GPU=1)"
elif [ "${TRACE_BAR_MMIO:-0}" = "1" ]; then
  echo "    BAR mmap DISABLED (every MMIO traps -- slow boot; SIMD accesses skipped)"
  ARGS+=(-device "vfio-apple-pci,host=05:00.0,dma-companion=on,trace-bar-mmio=on")
else
  ARGS+=(-device "vfio-apple-pci,host=05:00.0,dma-companion=on")
fi

case "$MODE" in
  perf|performance|"")
    echo "==> Performance mode (no tracing, no QMP)"
    ;;

  debug)
    echo "==> Debug mode (QMP at $QMP_SOCK, tracing armed but disabled)"
    rm -f "$QMP_SOCK"
    ARGS+=(
      -qmp "unix:${QMP_SOCK},server=on,wait=off"
      -trace "file=${TRACE_BIN_PREFIX}"
    )
    echo "    Toggle events with:  ./trace-control.sh on <glob>"
    echo "    Disable with:        ./trace-control.sh off <glob>"
    echo "    Trace file prefix:   ${TRACE_BIN_PREFIX}-<pid>"
    ;;

  trace|tracing)
    if [ ! -f "$EVENTS_FILE" ]; then
      echo "ERROR: $EVENTS_FILE not found. Create it with one event-name (or glob) per line." >&2
      echo "       Example contents:" >&2
      echo "         apple_dma_*" >&2
      echo "         apple_dext_*" >&2
      echo "         vfio_msi_interrupt" >&2
      echo "         vfio_iommu_map_notify" >&2
      exit 1
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
    echo "Usage: $0 [perf|debug|trace]" >&2
    echo "  perf  : no tracing (default)" >&2
    echo "  debug : QMP open, events armed but off (toggle live)" >&2
    echo "  trace : tracing from boot via $EVENTS_FILE" >&2
    exit 1
    ;;
esac

if [ "${NO_GPU:-0}" != "1" ]; then
  echo "    GPU passthrough: 05:00.0 via vfio-apple-pci (dma-companion=on)"
fi
echo "    Guest SSH:       ssh -p 2222 geramy@127.0.0.1"
echo ""

exec "$QEMU" "${ARGS[@]}"
