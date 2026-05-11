#!/usr/bin/env bash
#
# First-time Windows 11 ARM install boot.
#
# Boots the Windows installer with:
#   - Windows 11 ARM ISO as primary CD
#   - virtio-win.iso as secondary CD (so installer can load virtio-blk driver)
#   - swtpm-backed TPM 2.0 (Windows 11 hard requirement)
#   - 64GB virtio-blk install target (windows-arm.qcow2, auto-created if missing)
#   - No GPU passthrough yet -- we add that later via launch-windows.sh
#
# Required env (or fall back to defaults):
#   WIN_ISO     : path to Windows 11 ARM ISO       (default: newest Win11_*ARM* in ~/Downloads)
#   VIRTIO_ISO  : path to virtio-win.iso           (default: ~/Downloads/virtio-win.iso)
#   WIN_DISK    : install target qcow2             (default: ./windows-arm.qcow2)
#   WIN_DISK_SZ : disk size if creating            (default: 64G)
#
# During install:
#   1. Boot from the Windows ISO (autoselect or press a key when prompted)
#   2. When the installer asks "Where do you want to install Windows?", click
#      "Load driver" and browse the second CD (virtio-win) -> select the ARM64
#      folder for the running Windows version (e.g. amd64/win11 -> the ARM
#      branch is under arm64/...). Pick "Red Hat VirtIO SCSI controller".
#   3. The 64GB virtio-blk disk becomes visible. Install onto it.
#   4. Windows reboots a few times -- let it finish OOBE.
#   5. Inside Windows: shutdown /s /t 0
#   6. Then run launch-windows.sh to boot the installed system.

set -euo pipefail
cd "$(dirname "$0")"

WIN_ISO="${WIN_ISO:-}"
if [ -z "$WIN_ISO" ]; then
  WIN_ISO=$(ls -t ~/Downloads/Win11_*ARM*.iso ~/Downloads/Windows11_*ARM*.iso 2>/dev/null | head -1 || true)
fi
VIRTIO_ISO="${VIRTIO_ISO:-$HOME/Downloads/virtio-win.iso}"
WIN_DISK="${WIN_DISK:-$(pwd)/windows-arm.qcow2}"
WIN_DISK_SZ="${WIN_DISK_SZ:-64G}"

if [ -z "$WIN_ISO" ] || [ ! -f "$WIN_ISO" ]; then
  echo "ERROR: Windows 11 ARM ISO not found." >&2
  echo "  Set WIN_ISO=/path/to/Win11_*ARM*.iso or drop it in ~/Downloads/" >&2
  exit 1
fi

# Safety: refuse to clobber the Linux disks.
case "$(basename "$WIN_DISK")" in
  safety_overlay.qcow2|my_linux_ssd.qcow2)
    echo "ERROR: WIN_DISK points at a Linux disk ($WIN_DISK). Refusing to overwrite." >&2
    echo "       Unset WIN_DISK or pick a different filename." >&2
    exit 1
    ;;
esac
if [ ! -f "$VIRTIO_ISO" ]; then
  echo "ERROR: virtio-win.iso not found at $VIRTIO_ISO" >&2
  echo "  Download: curl -L -o ~/Downloads/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" >&2
  exit 1
fi
if ! command -v swtpm >/dev/null; then
  echo "ERROR: swtpm not installed. Install with: brew install swtpm" >&2
  exit 1
fi

# Create the install-target disk if it doesn't exist.
if [ ! -f "$WIN_DISK" ]; then
  echo "Creating $WIN_DISK ($WIN_DISK_SZ)..."
  ./build/qemu-img create -f qcow2 "$WIN_DISK" "$WIN_DISK_SZ"
fi

# Create UEFI vars file (writable per-VM) if missing.
UEFI_VARS="$(pwd)/uefi-vars-windows.fd"
if [ ! -f "$UEFI_VARS" ]; then
  echo "Creating writable UEFI vars at $UEFI_VARS..."
  # 64MB matches the code.fd size; QEMU expects matching size.
  dd if=/dev/zero of="$UEFI_VARS" bs=1m count=64 2>/dev/null
fi

# Start swtpm in a per-launch socket directory.
TPM_DIR="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TPM_DIR"' EXIT

swtpm socket \
  --tpm2 \
  --tpmstate "dir=$TPM_DIR,mode=0600" \
  --ctrl "type=unixio,path=$TPM_DIR/swtpm-sock" \
  --log "level=20" \
  --terminate &

# Wait for swtpm socket to appear.
for _ in $(seq 1 50); do
  [ -S "$TPM_DIR/swtpm-sock" ] && break
  sleep 0.1
done
if [ ! -S "$TPM_DIR/swtpm-sock" ]; then
  echo "ERROR: swtpm did not start within 5 seconds" >&2
  exit 1
fi

echo "==> Booting Windows installer"
echo "    Windows ISO: $WIN_ISO"
echo "    VirtIO ISO:  $VIRTIO_ISO"
echo "    Install to:  $WIN_DISK ($WIN_DISK_SZ)"
echo "    TPM socket:  $TPM_DIR/swtpm-sock"
echo ""

exec ./build/qemu-system-aarch64 \
  -machine virt,highmem=on,memory-backend=pc.ram \
  -accel hvf,tso=on \
  -cpu host \
  -smp 4 \
  -m 8G \
  -object memory-backend-ram,id=pc.ram,size=8G,prealloc=on,share=off \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file="$UEFI_VARS" \
  -device virtio-gpu-pci \
  -display cocoa \
  -device qemu-xhci,id=xhci \
  -device usb-kbd,bus=xhci.0 \
  -device usb-tablet,bus=xhci.0 \
  -chardev "socket,id=chrtpm,path=$TPM_DIR/swtpm-sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis-device,tpmdev=tpm0 \
  -drive "if=none,id=hd0,file=$WIN_DISK,format=qcow2,cache=writeback,discard=unmap" \
  -device virtio-blk-pci,drive=hd0,bootindex=2 \
  -drive "if=none,id=cd0,file=$WIN_ISO,format=raw,media=cdrom,readonly=on" \
  -device usb-storage,drive=cd0,bus=xhci.0,bootindex=1 \
  -drive "if=none,id=cd1,file=$VIRTIO_ISO,format=raw,media=cdrom,readonly=on" \
  -device usb-storage,drive=cd1,bus=xhci.0 \
  -netdev user,id=net0,hostfwd=tcp::2223-:3389 \
  -device virtio-net-pci,netdev=net0
