/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * FDT generator for vfio-apple-pci bounce-buffer reserved memory.
 *
 * Lives in a per-target source file (specific_ss) so it can reference
 * libfdt helpers gated on CONFIG_DEVICE_TREE; apple-device.c itself is
 * compiled once for all softmmu targets and cannot pull in libfdt.
 *
 * Copyright (c) 2026 Scott J. Goldman
 */

#include "qemu/osdep.h"

#include "hw/pci/pci.h"
#include "hw/vfio/apple.h"
#include "system/device_tree.h"

void apple_vfio_add_bounce_fdt_nodes(void *fdt, const char *pciehb_nodename)
{
    VFIOAppleBounceList *list = apple_vfio_get_bounce_buffers();
    VFIOAppleBounceBuffer *bb;
    bool have_reserved_memory = false;
    int pool_idx = 0;

    QLIST_FOREACH(bb, list, next) {
        char *pool_node, *dev_node;
        uint32_t phandle;

        if (!bb->mapped) {
            continue;
        }

        if (!have_reserved_memory) {
            qemu_fdt_add_subnode(fdt, "/reserved-memory");
            qemu_fdt_setprop_cell(fdt, "/reserved-memory",
                                  "#address-cells", 2);
            qemu_fdt_setprop_cell(fdt, "/reserved-memory", "#size-cells", 2);
            qemu_fdt_setprop(fdt, "/reserved-memory", "ranges", NULL, 0);
            have_reserved_memory = true;
        }

        phandle = qemu_fdt_alloc_phandle(fdt);

        pool_node = g_strdup_printf("/reserved-memory/dma-pool%d@%" PRIx64,
                                    pool_idx, bb->iova);
        qemu_fdt_add_subnode(fdt, pool_node);
        qemu_fdt_setprop_string(fdt, pool_node,
                                "compatible", "restricted-dma-pool");
        qemu_fdt_setprop_sized_cells(fdt, pool_node, "reg",
                                     2, bb->iova, 2, bb->size);
        qemu_fdt_setprop_cell(fdt, pool_node, "phandle", phandle);
        g_free(pool_node);

        dev_node = g_strdup_printf("%s/vfio@%x,%x", pciehb_nodename,
                                   PCI_SLOT(PCI_DEVFN(bb->pci_slot,
                                                      bb->pci_func)),
                                   PCI_FUNC(PCI_DEVFN(bb->pci_slot,
                                                      bb->pci_func)));
        qemu_fdt_add_subnode(fdt, dev_node);
        /*
         * PCI device DT reg: phys.hi = config space address encoding,
         * phys.mid = phys.lo = 0, size.hi = size.lo = 0.
         */
        qemu_fdt_setprop_cells(fdt, dev_node, "reg",
                               (bb->pci_bus << 16) |
                               (PCI_DEVFN(bb->pci_slot, bb->pci_func) << 8),
                               0, 0, 0, 0);
        qemu_fdt_setprop_cell(fdt, dev_node, "memory-region", phandle);
        g_free(dev_node);

        pool_idx++;
    }
}
