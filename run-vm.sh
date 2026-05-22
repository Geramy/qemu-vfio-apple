#!/bin/bash
# QEMU VFIO VM Launch Script with GPU Passthrough via vfio-user
# Requires: Razer Thunderbolt dock with AMD GPU connected
# Usage: ./run-vm.sh

# No set -e: we want to warn but continue even if devices aren't bound yet
# set -e

# Configuration
VM_NAME="ubuntu-26-vm"
DISK_IMAGE="$(dirname "$0")/ubuntu-26-disk.qcow2"
ISO_IMAGE="/Users/geramyloveless/Downloads/ubuntu-26.04-desktop-amd64.iso"
QEMU_VFIO="/Applications/VFIOUserHostApp.app/Contents/MacOS/qemu-vfio-apple"
QEMU_SYSTEM="$(which qemu-system-x86_64)"

# Memory and CPU configuration
MEM_SIZE="64G"
CPU_CORES="8"

# AMD RX 6600 PCI IDs (0x1002:0x7551 for display, 0x1002:0xab40 for audio)
# Device detected at 05:00.0 / 05:00.1
GPU_BDF="05:00"

# Determine mode
INSTALL_MODE=false
if [[ "${1:-}" == "install" ]]; then
    INSTALL_MODE=true
fi

# Check dependencies
if [ ! -f "$QEMU_VFIO" ]; then
    echo "Error: qemu-vfio-apple CLI tool not found at $QEMU_VFIO"
    exit 1
fi

echo "======================================"
echo "  QEMU VFIO VM - $VM_NAME"
echo "  GPU Passthrough: $GPU_BDF (AMD Radeon AI R9700 Pro)"
echo "======================================"
echo ""

# Check driver status
echo "Checking driver status..."
"$QEMU_VFIO" driver-status 2>&1 || true
echo ""

# List devices
echo "Listing PCI devices..."
"$QEMU_VFIO" list-devices 2>&1 || true
echo ""

# Check if GPU is bound to vfio-user
"$QEMU_VFIO" list-devices 2>&1 | grep -E "0[5]:00\.(0|1)" | grep "vfio-user" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "WARNING: AMD GPU at $GPU_BDF is NOT bound to vfio-user driver."
    echo "The GPU devices show as (unbound). To pass through the GPU:"
    echo "  1. macOS native drivers must be detached (requires kext unload or reboot)"
    echo "  2. Or add device IDs to the DriverKit IOKitPersonalities match and rebuild"
    echo ""
    echo "Proceeding anyway — the CLI tool's --passthrough flag will attempt to attach..."
fi

echo ""
echo "Launching VM with GPU passthrough..."
echo ""

# Run with vfio-user GPU passthrough
"$QEMU_VFIO" \
    --cpus "$CPU_CORES" \
    --memory "$MEM_SIZE" \
    --passthrough "$GPU_BDF" \
    --disk "$DISK_IMAGE" \
    --ssh-port 2222 \
    "$@" 2>&1
