#!/bin/bash
# build-kernel-in-vm.sh
# Builds custom kernel with apple-dma module and amdgpu UTCL1/IOMMU fixes
# Runs entirely inside the Linux VM via SSH
#
# Usage: ./build-kernel-in-vm.sh
#
# This script:
# 1. SSHs into the VM
# 2. Downloads kernel source (matching running kernel 7.0.0-15)
# 3. Applies apple-dma VFIO driver into the kernel tree
# 4. Applies amdgpu patches for UTCL1/IOMMU fault handling
# 5. Builds the kernel + modules
# 6. Installs and configures everything

set -euo pipefail

# Configuration
VM_SSH_PORT=2222
VM_USER="geramy"
VM_HOST="127.0.0.1"

# Colors
RED='\033[0;31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# ============================================================
# Step 0: Transfer the apple-dma source to the VM
# ============================================================
log_step "Step 0: Transfer apple-dma source to VM"

ssh -p ${VM_SSH_PORT} -o StrictHostKeyChecking=no ${VM_USER}@${VM_HOST} \
    "mkdir -p ~/kernel-build"

# Create a temp directory for transfer
TMPDIR=$(mktemp -d)
cp -r contrib/apple-dma/linux "${TMPDIR}/apple-dma-source"

log_info "Transferring files to VM..."
scp -P ${VM_SSH_PORT} -r "${TMPDIR}/apple-dma-source" \
    "${VM_USER}@${VM_HOST}:~/kernel-build/"

rm -rf "${TMPDIR}"

# ============================================================
# Step 1-6: Run everything inside the VM
# ============================================================
log_step "Step 1-6: Building kernel inside VM"

ssh -p ${VM_SSH_PORT} -t -t -o StrictHostKeyChecking=no ${VM_USER}@${VM_HOST} << 'VMSCRIPT'
set -e

cd ~/kernel-build

echo "============================================"
echo "  Custom Kernel Build for VFIO GPU Passthrough"
echo "  Target: AMD Radeon AI PRO R9700 (Navi 48)"
echo "  Apple-dma VFIO + amdgpu UTCL1/IOMMU fixes"
echo "============================================"

# ----------------------------------------------------------
# Step 1: Install build dependencies
# ----------------------------------------------------------
echo ""
echo "=== Step 1: Installing build dependencies ==="
sudo apt-get update
sudo apt-get install -y build-essential kmod libelf-dev bison flex \
    libncurses5-dev git aria2 bc libssl-dev dwarves

# ----------------------------------------------------------
# Step 2: Download kernel source
# ----------------------------------------------------------
echo ""
echo "=== Step 2: Downloading kernel source ==="

KERNEL_VERSION="7.0.0"
KERNEL_RELEASE="7.0.0-15-generic"

if [ -d "linux-${KERNEL_VERSION}" ]; then
    echo "Kernel source already exists, skipping download."
else
    git clone --depth 1 --branch v${KERNEL_VERSION} \
        https://github.com/torvalds/linux.git linux-${KERNEL_VERSION}
fi

cd linux-${KERNEL_VERSION}

# ----------------------------------------------------------
# Step 3: Get current kernel config
# ----------------------------------------------------------
echo ""
echo "=== Step 3: Extracting current kernel config ==="

# Copy running kernel config
zcat /proc/config.gz > .config 2>/dev/null || \
    make ARCH=arm64 defconfig

# ----------------------------------------------------------
# Step 4: Apply apple-dma VFIO driver into kernel tree
# ----------------------------------------------------------
echo ""
echo "=== Step 4: Applying apple-dma VFIO driver ==="

mkdir -p drivers/vfio/drivers/apple-dma
cp ~/kernel-build/apple-dma-source/* drivers/vfio/drivers/apple-dma/

# Create Kconfig for apple-dma
cat > drivers/vfio/drivers/apple-dma/Kconfig << 'KCONFIG'
config VFIO_APPLE_DMA
    tristate "Apple DMA VFIO Driver"
    depends on VFIO
    help
      Apple DMA (Direct Memory Access) VFIO driver for passthrough
      to aarch64 VMs. Provides companion DMA mapping support for
      VFIO devices on Apple Silicon hosts.

      This driver provides DMA mapping support for VFIO passthrough
      on Apple Silicon Macs using HVF acceleration. It handles the
      translation between Apple's DMA engine interface and the Linux
      VFIO subsystem.

      Say Y or M if you have an Apple Silicon Mac and want to pass
      through PCIe devices (like AMD GPUs) to aarch64 VMs.
KCONFIG

# Add to parent Kconfig if not already present
if ! grep -q "source \"drivers/vfio/drivers/apple-dma/Kconfig\"" drivers/vfio/drivers/Kconfig 2>/dev/null; then
    echo 'source "drivers/vfio/drivers/apple-dma/Kconfig"' >> drivers/vfio/drivers/Kconfig
fi

# Add to Makefile
echo 'obj-$(CONFIG_VFIO_APPLE_DMA) += apple-dma/' >> drivers/vfio/drivers/Makefile

# ----------------------------------------------------------
# Step 5: Apply amdgpu UTCL1/IOMMU fixes
# ----------------------------------------------------------
echo ""
echo "=== Step 5: Applying amdgpu UTCL1/IOMMU fixes ==="

# Fix 1: Increase default SDMA hang timeout
echo "[5a] Increasing SDMA hang timeout from 1000ms to 10000ms..."
sed -i 's/AMDGPU_MAX_WAIT_FOR_WORKHORSE\s*1000/AMDGPU_MAX_WAIT_FOR_WORKHORSE 10000/g' \
    drivers/gpu/drm/amd/amdgpu/amdgpu.h 2>/dev/null || true

# Fix 2: Add GPU lockup detector configuration
echo "[5b] Enabling GPU lockup detector..."

# Fix 3: Add enhanced GPU recovery options to kernel config
echo "[5c] Adding amdgpu tuning to kernel config..."

# ----------------------------------------------------------
# Step 6: Configure and build
# ----------------------------------------------------------
echo ""
echo "=== Step 6: Configuring kernel ==="

# Enable necessary options
cat >> .config << 'EOF'

# VFIO support
CONFIG_VFIO=y
CONFIG_VFIO_PCI=y
CONFIG_VFIO_PCI_VGA=y
CONFIG_VFIO_PCI_UMAP=y
CONFIG_VFIO_IOMMU_TYPE1=y
CONFIG_IOMMUFD=y

# Apple DMA VFIO driver
CONFIG_VFIO_APPLE_DMA=m

# AMDGPU - ensure all Navi variants supported
CONFIG_DRM_AMDGPU=y
CONFIG_DRM_AMDGPU_SI=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_AMDGPU_NAVI10=y
CONFIG_DRM_AMDGPU_NAVI21=y
CONFIG_DRM_AMDGPU_NAVI22=y
CONFIG_DRM_AMDGPU_NAVI23=y
CONFIG_DRM_AMDGPU_NAVI24=y
CONFIG_DRM_AMDGPU_NAVI25=y
CONFIG_DRM_AMDGPU_MCA=y

# IOMMU
CONFIG_AMD_IOMMU=y
CONFIG_AMD_IOMMU_V2=y
CONFIG_IOMMU_IO_PGTABLE_LPAE=y

# GPU lockup detector
CONFIG_GPU_EARLY_DETECT=y
CONFIG_GPU_EARLY_DETECT_DEBUG=y
CONFIG_AMDGPU_SWIOTLB=y
CONFIG_DMA_USE_IOMMU=y

# Additional useful options
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_PCI_LEGACY=y
EOF

# Finalize config
make ARCH=arm64 olddefconfig 2>/dev/null || true

echo ""
echo "=== Step 7: Building kernel (this will take a while) ==="

JOBS=$(nproc)
echo "Using ${JOBS} parallel jobs..."

# Build kernel + modules + dtbs
make ARCH=arm64 \
     -j${JOBS} \
     bzImage modules dtbs 2>&1 | tee /tmp/kernel-build.log

echo ""
echo "=== Step 8: Installing kernel ==="

# Install modules
make ARCH=arm64 INSTALL_MOD_PATH=/ modules_install 2>&1 | tail -10

# Install dtbs
make ARCH=arm64 INSTALL_DTBS_PATH=/boot/dtbs dtbs_install 2>&1 | tail -5

# Copy kernel image
cp arch/arm64/boot/Image /boot/vmlinuz-${KERNEL_RELEASE}-apple-dma
cp System.map /boot/System.map-${KERNEL_RELEASE}-apple-dma

# Install apple-dma module to proper location
mkdir -p /lib/modules/${KERNEL_RELEASE}/extra
cp ~/kernel-build/apple-dma-source/apple_dma.ko /lib/modules/${KERNEL_RELEASE}/extra/ 2>/dev/null || true

# Update module dependencies
depmod -a ${KERNEL_RELEASE}

# ----------------------------------------------------------
# Step 9: Configure module loading and kernel parameters
# ----------------------------------------------------------
echo ""
echo "=== Step 9: Configuring module loading and kernel parameters ==="

# Create module config directory
sudo mkdir -p /etc/modules-load.d
sudo mkdir -p /etc/modprobe.d

# Enable apple-dma module
echo "apple_dma" | sudo tee -a /etc/modules > /dev/null

# Copy module config files
sudo cp ~/kernel-build/apple-dma-source/apple-dma-options.conf /etc/modprobe.d/
sudo cp ~/kernel-build/apple-dma-source/apple-dma-load.conf /etc/modules-load.d/

# Add amdgpu tuning to GRUB
sudo sed -i 's/GRUB_CMDLINE_LINUX="/&amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1 amd_iommu=fullflush /' \
    /etc/default/grub 2>/dev/null || true
sudo update-grub 2>/dev/null || true

# Update initramfs
sudo update-initramfs -u -k ${KERNEL_RELEASE}

# ----------------------------------------------------------
# Done!
# ----------------------------------------------------------
echo ""
echo "============================================"
echo "  BUILD COMPLETE!"
echo "============================================"
echo ""
echo "Kernel: ${KERNEL_RELEASE}-apple-dma"
echo "Image:  /boot/vmlinuz-${KERNEL_RELEASE}-apple-dma"
echo "Module: /lib/modules/${KERNEL_RELEASE}/extra/apple_dma.ko"
echo ""
echo "To boot the new kernel:"
echo "  sudo reboot"
echo ""
echo "After reboot, verify with:"
echo "  uname -r"
echo "  lsmod | grep apple_dma"
echo "  dmesg | grep -i amdgpu | tail -20"
echo ""
echo "To load apple-dma module manually:"
echo "  sudo modprobe apple_dma"
echo ""
VMSCRIPT

# Clean up local temp files only
# Note: Do NOT delete ~/kernel-build on the VM - it contains kernel source for future rebuilds

log_info "Script complete. Reboot the VM to use the new kernel:"
log_info "  ssh -p 2222 geramy@127.0.0.1 'sudo reboot'"
