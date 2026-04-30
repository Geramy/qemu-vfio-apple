// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * uvm_page_patch - Override UVM large-page requests via kprobe.
 *
 * The NVIDIA UVM driver explicitly requests 2 MB or 64 KB page sizes
 * when allocating system memory through nvUvmInterfaceMemoryAllocSys.
 * The RM layer then asserts that the DMA address (IOVA) is aligned to
 * the requested page size.  On Apple Silicon the DART provides the
 * IOVA and its alignment cannot be controlled, so the assertion fires
 * with NV_ERR_INVALID_OFFSET.
 *
 * We place a kprobe on nvUvmInterfaceMemoryAllocSys (EXPORT_SYMBOL in
 * the nvidia module).  The pre-handler rewrites any explicit large
 * page-size request to UVM_PAGE_SIZE_DEFAULT (0), which causes RM to
 * call _memmgrGetOptimalSysmemPageSize and check alignment *before*
 * selecting a larger page size.
 */

#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/version.h>

#include "uvm_page_patch.h"

/*
 * UvmGpuAllocInfo layout (from nv_uvm_types.h):
 *   offset 0:  NvU64 gpuPhysOffset
 *   offset 8:  NvU64 pageSize        <-- target field
 *   offset 16: NvU64 alignment
 *   ...
 *
 * Known valid pageSize values:
 *   0x000000  UVM_PAGE_SIZE_DEFAULT
 *   0x010000  UVM_PAGE_SIZE_64K
 *   0x200000  UVM_PAGE_SIZE_2M
 */
#define UVM_ALLOC_INFO_GPU_PHYS_OFF_OFF	0
#define UVM_ALLOC_INFO_PAGE_SIZE_OFF	8
#define UVM_ALLOC_INFO_ALIGNMENT_OFF	16

#define UVM_PAGE_SIZE_DEFAULT		0x0ULL
#define UVM_PAGE_SIZE_64K		0x10000ULL
#define UVM_PAGE_SIZE_2M		0x200000ULL

#define UVM_PATCH_MAX_ANOMALIES		5

static DEFINE_MUTEX(uvm_patch_lock);
static bool kprobe_registered;
static bool notifier_registered;
static bool uvm_patch_disabled;

static atomic_t uvm_patch_count = ATOMIC_INIT(0);
static atomic_t uvm_anomaly_count = ATOMIC_INIT(0);

/*
 * Validate that the allocInfo pointer looks sane and the struct layout
 * matches what we expect.  Returns true if safe to override.
 */
static bool uvm_validate_alloc_info(u64 alloc_info_ptr, u64 page_size,
				    u64 length)
{
	u64 gpu_phys_offset, alignment;
	int anomalies;

	/* Pointer must be in kernel address space */
	if (alloc_info_ptr < PAGE_OFFSET)
		goto anomaly;

	/* pageSize must be exactly one of the known values */
	if (page_size != UVM_PAGE_SIZE_64K &&
	    page_size != UVM_PAGE_SIZE_2M)
		goto anomaly;

	/*
	 * gpuPhysOffset (offset 0) is an output field; callers zero-init
	 * the struct, so it should be 0 at entry.
	 */
	gpu_phys_offset = *(u64 *)(alloc_info_ptr + UVM_ALLOC_INFO_GPU_PHYS_OFF_OFF);
	if (gpu_phys_offset != 0)
		goto anomaly;

	/*
	 * alignment (offset 16) should be a power of 2 or 0.
	 */
	alignment = *(u64 *)(alloc_info_ptr + UVM_ALLOC_INFO_ALIGNMENT_OFF);
	if (alignment != 0 && (alignment & (alignment - 1)) != 0)
		goto anomaly;

	return true;

anomaly:
	anomalies = atomic_inc_return(&uvm_anomaly_count);
	pr_warn("apple_dma: uvm_page_patch: anomaly #%d: "
		"ptr=0x%llx pageSize=0x%llx length=%llu\n",
		anomalies, alloc_info_ptr, page_size, length);
	if (anomalies >= UVM_PATCH_MAX_ANOMALIES) {
		pr_err("apple_dma: uvm_page_patch: too many anomalies, "
		       "disabling -- struct layout may have changed\n");
		uvm_patch_disabled = true;
	}
	return false;
}

static int uvm_alloc_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	u64 alloc_info_ptr;
	u64 *ps;
	u64 page_size, length;
	int cnt;

	if (unlikely(uvm_patch_disabled))
		return 0;

	/*
	 * ARM64 calling convention:
	 *   x1 = length (NvLength / NvU64)
	 *   x3 = UvmGpuAllocInfo *allocInfo
	 */
	length = regs->regs[1];
	alloc_info_ptr = regs->regs[3];
	ps = (u64 *)(alloc_info_ptr + UVM_ALLOC_INFO_PAGE_SIZE_OFF);
	page_size = *ps;

	if (page_size == UVM_PAGE_SIZE_DEFAULT)
		return 0;

	if (!uvm_validate_alloc_info(alloc_info_ptr, page_size, length))
		return 0;

	*ps = 0; /* UVM_PAGE_SIZE_DEFAULT */
	cnt = atomic_inc_return(&uvm_patch_count);
	if (cnt <= 8 || (cnt & (cnt - 1)) == 0)
		pr_info("apple_dma: uvm_page_patch: #%d overrode "
			"pageSize 0x%llx -> DEFAULT (length=%llu)\n",
			cnt, page_size, length);

	return 0;
}

static struct kprobe uvm_kp = {
	.symbol_name = "nvUvmInterfaceMemoryAllocSys",
	.pre_handler = uvm_alloc_pre_handler,
};

static void uvm_kprobe_register(void)
{
	int ret;

	if (kprobe_registered)
		return;

	ret = register_kprobe(&uvm_kp);
	if (ret == 0) {
		kprobe_registered = true;
		pr_info("apple_dma: uvm_page_patch: kprobe active on %s\n",
			uvm_kp.symbol_name);
	} else if (ret == -ENOENT) {
		pr_info("apple_dma: uvm_page_patch: %s not found yet\n",
			uvm_kp.symbol_name);
	} else {
		pr_warn("apple_dma: uvm_page_patch: kprobe register failed: %d\n",
			ret);
	}
}

static void uvm_kprobe_unregister(void)
{
	if (!kprobe_registered)
		return;

	unregister_kprobe(&uvm_kp);
	kprobe_registered = false;
	pr_info("apple_dma: uvm_page_patch: kprobe removed\n");
}

static void uvm_log_module_version(struct module *mod)
{
	const char *ver = mod->version;

	pr_info("apple_dma: uvm_page_patch: nvidia module version: %s\n",
		ver ? ver : "(unknown)");
}

static int uvm_module_notify(struct notifier_block *nb, unsigned long action,
			     void *data)
{
	struct module *mod = data;

	if (strcmp(mod->name, "nvidia") != 0)
		return NOTIFY_DONE;

	mutex_lock(&uvm_patch_lock);
	switch (action) {
	case MODULE_STATE_LIVE:
		uvm_log_module_version(mod);
		uvm_kprobe_register();
		break;
	case MODULE_STATE_GOING:
		uvm_kprobe_unregister();
		break;
	}
	mutex_unlock(&uvm_patch_lock);

	return NOTIFY_OK;
}

static struct notifier_block uvm_mod_nb = {
	.notifier_call = uvm_module_notify,
};

int uvm_page_patch_init(void)
{
	int ret;

	mutex_lock(&uvm_patch_lock);

	ret = register_module_notifier(&uvm_mod_nb);
	if (ret) {
		pr_err("apple_dma: uvm_page_patch: module notifier failed: %d\n",
		       ret);
		mutex_unlock(&uvm_patch_lock);
		return ret;
	}
	notifier_registered = true;

	/* nvidia may already be loaded */
	uvm_kprobe_register();

	mutex_unlock(&uvm_patch_lock);
	return 0;
}

void uvm_page_patch_exit(void)
{
	mutex_lock(&uvm_patch_lock);

	uvm_kprobe_unregister();

	if (notifier_registered) {
		unregister_module_notifier(&uvm_mod_nb);
		notifier_registered = false;
	}

	mutex_unlock(&uvm_patch_lock);
}
