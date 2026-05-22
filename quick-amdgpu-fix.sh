#!/bin/bash
# quick-amdgpu-fix.sh
# Applies amdgpu kernel parameters WITHOUT rebuilding the kernel
# This is a temporary workaround to test if kernel params help with SDMA hangs
#
# Usage: ./quick-amdgpu-fix.sh
#
# This script:
# 1. SSHs into the VM
# 2. Updates GRUB with amdgpu tuning parameters
# 3. Updates initramfs
# 4. Reboots the VM

set -euo pipefail

VM_SSH_PORT=2222
VM_USER="geramy"
VM_HOST="127.0.0.1"

RED='\033[0;31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

log_step "Quick amdgpu Fix - No kernel rebuild required"

log_info "Applying kernel parameters to VM..."

ssh -p ${VM_SSH_PORT} -t -t -o StrictHostKeyChecking=no ${VM_USER}@${VM_HOST} << 'VMSCRIPT'
set -e

echo "============================================"
echo "  Quick amdgpu Fix - Kernel Parameters Only"
echo "  No kernel rebuild required!"
echo "============================================"

# ----------------------------------------------------------
# Step 1: Apply GRUB kernel parameters
# ----------------------------------------------------------
echo ""
echo "=== Step 1: Updating GRUB kernel parameters ==="

# Check if parameters already exist
if grep -q "amdgpu.lockup_timeout=10000" /etc/default/grub 2>/dev/null; then
    echo "Parameters already applied, skipping."
else
    # Add amdgpu tuning parameters
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1 amd_iommu=fullflush iommu=pt /' /etc/default/grub
    echo "GRUB parameters added:"
    grep GRUB_CMDLINE_LINUX /etc/default/grub
fi

# ----------------------------------------------------------
# Step 2: Update GRUB and initramfs
# ----------------------------------------------------------
echo ""
echo "=== Step 2: Updating GRUB and initramfs ==="

sudo update-grub 2>&1 | tail -5
sudo update-initramfs -u -k all

# ----------------------------------------------------------
# Step 3: Apply runtime parameters (no reboot needed for these)
# ----------------------------------------------------------
echo ""
echo "=== Step 3: Applying runtime kernel parameters ==="

# These take effect immediately without reboot
sudo sysctl -w kernel.printk="3 3 3 3" 2>/dev/null || true

# Check if amdgpu is loaded
if lsmod | grep -q amdgpu; then
    echo "amdgpu module is loaded."
    echo ""
    echo "Runtime parameters that can be applied (no reboot):"
    echo ""
    echo "  # Increase GPU hang timeout (requires amdgpu reload):"
    echo "  sudo modprobe -r amdgpu"
    echo "  sudo modprobe amdgpu lockup_timeout=10000"
    echo ""
    echo "  # Or write to sysfs if supported:"
    echo "  echo 10000 | sudo tee /sys/module/amdgpu/parameters/gc_seq_debug 2>/dev/null || true"
    echo ""
else
    echo "amdgpu module is NOT currently loaded (GPU may be passthrough)."
fi

# ----------------------------------------------------------
# Step 4: Show current amdgpu settings
# ----------------------------------------------------------
echo ""
echo "=== Step 4: Current amdgpu module parameters ==="

if [ -f /sys/module/amdgpu/parameters/lockup_timeout ]; then
    echo "Current lockup_timeout: $(cat /sys/module/amdgpu/parameters/lockup_timeout)"
else
    echo "lockup_timeout sysfs not available (may need kernel rebuild for this parameter)."
fi

if [ -f /sys/module/amdgpu/parameters/gpu_recovery ]; then
    echo "Current gpu_recovery: $(cat /sys/module/amdgpu/parameters/gpu_recovery)"
else
    echo "gpu_recovery sysfs not available."
fi

# ----------------------------------------------------------
# Done
# ----------------------------------------------------------
echo ""
echo "============================================"
echo "  QUICK FIX COMPLETE!"
echo "============================================"
echo ""
echo "Kernel parameters added to GRUB:"
echo "  amdgpu.lockup_timeout=10000"
echo "  amdgpu.gpu_recovery=1"
echo "  amd_iommu=fullflush"
echo "  iommu=pt"
echo ""
echo "To reboot and apply:"
echo "  sudo reboot"
echo ""
echo "To manually load amdgpu with custom params (after reboot):"
echo "  sudo modprobe -r amdgpu"
echo "  sudo modprobe amdgpu lockup_timeout=10000 gpu_recovery=1"
echo ""
echo "Test the GPU passthrough after reboot to see if"
echo "SDMA hangs are reduced."
echo ""
VMSCRIPT

log_info "Quick fix applied. Reboot the VM to test:"
log_info "  ssh -p 2222 geramy@127.0.0.1 'sudo reboot'"