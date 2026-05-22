# Linux kernel patches for AMD R9700 (Navi 48 / RDNA4) over Thunderbolt

Three patches developed against a 7.0.0-derived kernel for the Apple
Silicon TB5 passthrough setup. Two of them fix R9700 hardware quirks
and apply to **any** Linux host; one is specific to passthrough scenarios
where the host PCIe bridge can't provide a 32 GB prefetchable window.

## Patches

### 0001-pci-probe-adopt-orphaned-PCIe-Express-capability.patch
Adds `pci_scan_orphan_pcie_cap()` to `drivers/pci/probe.c`. Walks config
space offsets 0x40–0xFC looking for the PCIe Express capability header
(cap ID 0x10) when the legacy cap chain doesn't link to it.

**Why:** The AMD R9700 places its PCIe cap at offset 0x64 but does not
link it in the legacy cap chain (PM at 0x50 has `next_ptr=0xa0`,
skipping 0x64). Spec violation on AMD's side; Linux currently doesn't
work around it.

**Symptom without this patch:** the kernel sees the R9700 as a
conventional PCI device — no PCIe extended caps, no AER, no Resizable
BAR enumeration. `lspci -vvv` shows only the three legacy caps
(Vendor / PM / MSI), no `Capabilities: [100] ...` block.

### 0002-pci-pci_find_capability-fall-back-to-dev-pcie_cap.patch
Companion to patch 1. Makes `pci_find_capability(dev, PCI_CAP_ID_EXP)`
fall back to `dev->pcie_cap` when the legacy chain walk fails.

**Why:** Many callers re-derive the PCIe cap location via this function
and bypass `dev->pcie_cap`. Without this, `pci_save_state()` fails with
`"buffer not found in pci_save_pcie_state"`.

### 0003-amdgpu-small-BAR-fallback-for-Apple-Silicon-TB5-passthrough.patch
Patches `amdgpu_device_resize_fb_bar()` to skip the BAR release/resize
attempt when rebar can't actually grow the BAR. Clamps
`visible_vram_size` to the actual BAR length so TTM only CPU-maps what
fits.

**Why:** Apple Silicon's TB5 bridge has a ~260 MB prefetchable memory
window per downstream port — far too small for the R9700's 32 GB VRAM
aperture. Without this patch, amdgpu releases BAR0/BAR2, the resize
fails, and `gmc_v12_0_sw_init` returns `-ENODEV`.

## Which apply to your physical Linux box?

| Box | Patch 1 | Patch 2 | Patch 3 |
|---|---|---|---|
| Apple Silicon Mac (QEMU+vfio-apple) | yes | yes | yes |
| Bare-metal x86 Linux + TB5 dock (MS-S1 etc.) | yes | yes | **only if** dmesg shows `gmc_v12_0 sw_init failed -19` |

Patches 1 + 2 fix an R9700 hardware spec violation and are useful on
ANY host platform. Patch 3 is only needed when the host's PCIe
prefetchable memory window can't accommodate the full 32 GB BAR —
unlikely on x86 with `Above 4G Decoding` + `Resizable BAR Support`
enabled in BIOS.

## Applying

```sh
cd /path/to/your/linux/source
patch -p1 < 0001-pci-probe-adopt-orphaned-PCIe-Express-capability.patch
patch -p1 < 0002-pci-pci_find_capability-fall-back-to-dev-pcie_cap.patch
# Optional:
patch -p1 < 0003-amdgpu-small-BAR-fallback-for-Apple-Silicon-TB5-passthrough.patch
```

Patches 1 and 2 reference line numbers from the 7.0.0-pcifix tree.
For other upstream versions, the file structure is similar enough
that `patch` should apply with offsets, or you can read the comments
in each .patch and apply by hand — the changes are small.

After applying:
```sh
make oldconfig
make -j$(nproc)
sudo make modules_install install
sudo update-initramfs -u
```

## Verifying after reboot

Patch 1+2 working:
```
$ dmesg | grep -i "orphaned PCIe"
amdgpu 0000:??:??.?: found orphaned PCIe capability at 0x64 (not in legacy cap chain) - adopting as PCIe
$ sudo lspci -vvv -s <gpu> | grep "Capabilities: \[1"
# Should now list extended caps at 0x100, 0x150, 0x200 (Resizable BAR), etc.
```

Patch 3 working (only relevant on bridges with small pref windows):
```
$ dmesg | grep "small-BAR"
amdgpu 0000:??:??.?: small-BAR mode: BAR0=256M, VRAM=32624M, rebar max=256M (cannot grow) -- skipping resize
```
