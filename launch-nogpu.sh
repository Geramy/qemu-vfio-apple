#!/usr/bin/env bash
# Boot the guest WITHOUT GPU passthrough.
#
# Use this when:
#   - You need to edit /etc/default/grub or other guest config without risking
#     a DC-ZVA host panic from a faulty amdgpu code path.
#   - You want to rebuild the apple_dma kernel module in the guest without it
#     trying to bind to a vfio-apple-pci device that isn't there.
#
# apple_dma module still loads but has nothing to bind to -- harmless. No BAR
# is mmap'd, so DC-ZVA on MMIO cannot happen.
set -euo pipefail
cd "$(dirname "$0")"

exec ./build/qemu-system-aarch64 \
  -machine virt,highmem=on,memory-backend=pc.ram \
  -accel hvf,tso=on \
  -cpu host \
  -smp 4 \
  -m 8G \
  -object memory-backend-ram,id=pc.ram,size=8G,prealloc=on,share=off \
  -device virtio-gpu-pci \
  -display cocoa \
  -device virtio-keyboard-pci \
  -device virtio-tablet-pci \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -drive if=virtio,format=qcow2,file=./safety_overlay.qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0
