/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Apple/macOS VFIO passthrough common definitions.
 *
 * Copyright (c) 2026 Scott J. Goldman
 */

#ifndef HW_VFIO_APPLE_H
#define HW_VFIO_APPLE_H

#include <stdint.h>

#include "hw/vfio/pci.h"
#include "hw/vfio/vfio-container.h"
#include "qapi/error.h"
#include "qemu/event_notifier.h"
#include "qemu/queue.h"

#ifdef CONFIG_DARWIN
#include <IOKit/IOKitLib.h>
#else
typedef uintptr_t io_connect_t;
#define IO_OBJECT_NULL ((io_connect_t)0)
#endif

OBJECT_DECLARE_SIMPLE_TYPE(AppleVFIOContainer, VFIO_IOMMU_APPLE)

struct AppleVFIOContainer {
    VFIOContainer parent_obj;
    io_connect_t dext_conn;
    uint8_t host_bus;
    uint8_t host_device;
    uint8_t host_function;
    /*
     * Optional host PCI root name used to disambiguate when multiple
     * VFIOUserPCIDriver instances share the same BDF. NULL means
     * "uniquely matched without a hint". Owned by this struct.
     */
    char *host_root;
};

typedef struct AppleDextInterruptNotify AppleDextInterruptNotify;

typedef struct AppleVFIOBarMap {
    void *addr;
    size_t size;
} AppleVFIOBarMap;

typedef struct AppleVFIOState {
    AppleDextInterruptNotify *irq_notify;
    EventNotifier irq_notifier;
    uint32_t num_irq_vectors;
    AppleVFIOBarMap bar_maps[PCI_ROM_SLOT];
} AppleVFIOState;

OBJECT_DECLARE_SIMPLE_TYPE(VFIOApplePCIDevice, VFIO_APPLE_PCI)

typedef struct VFIOAppleBounceBuffer {
    MemoryRegion mr;            /* RAM backing the bounce buffer */
    void *host_addr;            /* mmap'd host virtual address */
    uint64_t iova;              /* IOVA returned by PrepareForDMA */
    uint64_t size;              /* total span in bytes (including gaps) */
    bool mapped;                /* true once identity-mapped in guest */
    uint8_t pci_bus;            /* guest PCI bus number */
    uint8_t pci_slot;           /* guest PCI slot */
    uint8_t pci_func;           /* guest PCI function */
    QLIST_ENTRY(VFIOAppleBounceBuffer) next;
} VFIOAppleBounceBuffer;

struct VFIOApplePCIDevice {
    VFIOPCIDevice parent_obj;
    AppleVFIOState *apple;
    DeviceState *dma_companion;
    bool dma_companion_autocreated;
    bool use_dma_companion;
    uint64_t dma_bounce_size;
    VFIOAppleBounceBuffer *bounce;
    /*
     * Optional `host-root=` property: the registry-entry name of the
     * topmost IOPCIDevice ancestor for the dext instance to bind to
     * (e.g. "pcic0-bridge"). Required only if multiple VFIOUserPCIDriver
     * instances claim the same BDF. NULL when the user didn't set it.
     */
    char *host_root;
};

extern VFIODeviceIOOps apple_vfio_device_io_ops;

bool apple_vfio_device_setup(VFIOApplePCIDevice *adev, Error **errp);
void apple_vfio_device_cleanup(VFIOApplePCIDevice *adev);
bool apple_vfio_get_bar_info(VFIOApplePCIDevice *adev, uint8_t bar,
                             uint8_t *mem_idx, uint64_t *size,
                             uint8_t *type);

/*
 * Shared dext-connection cache: a single io_connect_t is opened by the
 * vfio-apple-pci container and shared with the matching apple-dma-pci
 * companion. The cache is keyed by (bus, device, function, host_root)
 * so devices that share a BDF under different host roots stay distinct.
 * `host_root` may be NULL on both publish and lookup; NULL is treated
 * as a distinct key from any non-NULL string.
 */
bool apple_vfio_dext_publish(uint8_t bus, uint8_t device, uint8_t function,
                             const char *host_root, io_connect_t conn);
io_connect_t apple_vfio_dext_lookup(uint8_t bus, uint8_t device,
                                    uint8_t function,
                                    const char *host_root);
void apple_vfio_dext_release(uint8_t bus, uint8_t device, uint8_t function,
                             const char *host_root, io_connect_t conn);

/*
 * Global list of bounce buffers registered by vfio-apple-pci devices.
 * Used by the machine's DTB generator to add restricted-dma-pool nodes.
 */
typedef QLIST_HEAD(VFIOAppleBounceList, VFIOAppleBounceBuffer)
    VFIOAppleBounceList;

VFIOAppleBounceList *apple_vfio_get_bounce_buffers(void);
void apple_vfio_add_bounce_fdt_nodes(void *fdt, const char *pciehb_nodename);

#endif /* HW_VFIO_APPLE_H */
