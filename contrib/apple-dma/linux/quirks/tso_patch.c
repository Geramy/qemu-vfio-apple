// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * tso_patch - emulate Hector Martin's PR_{GET,SET}_MEM_MODEL prctl ABI
 *             when Apple TSO mode is enabled by the hypervisor.
 *
 * Background
 * ----------
 * On Apple silicon under HVF, ACTLR_EL1 bit 1 ("Apple TSO") switches
 * the vCPU to a total-store-ordering memory model.  The only
 * reliable way to enable it is to have QEMU set the bit at
 * vcpu-init time, before the vCPU executes its first instruction:
 *
 *     -accel hvf,tso=on
 *
 * Why we don't flip the bit from the guest
 * ----------------------------------------
 * Earlier versions of this module flipped EnTSO from inside the
 * guest after boot.  We tried every plausible hardening we could
 * think of: stop_machine() to quiesce every CPU, sequential token-
 * passing so only one CPU was mid-flip at a time, broadcast inner-
 * shareable TLB invalidates on both sides of the MSR, I-cache
 * invalidates, and synchronous vmexits via a PSCI_VERSION HVC to
 * force HVF to save+reload vCPU state.  Kitchen-sink mode still
 * produced intermittent late-boot kernel paging faults on roughly
 * half of boots under a real workload.
 *
 * This matches the underlying microarchitectural reality: changing
 * the memory-ordering bit on a CPU that already has live TLB
 * entries / in-flight stores / a populated load-store queue is
 * unspecified on Apple silicon, and HVF does not appear to offer a
 * way to quiesce the vCPU deeply enough to flip it safely.
 *
 * Note that Hector Martin's downstream arm64 patches[1] flip EnTSO
 * per-process in __switch_to() and are stable, but they run on
 * bare-metal Asahi where the flip happens at a natural quiescent
 * point (a context switch: TLB context switch, ASID swap, barriers
 * already in place) and there is no hypervisor in the loop
 * maintaining stage-2 caches keyed on EnTSO state.  We can't
 * manufacture an equivalent quiescent point from inside an HVF
 * guest, so we don't try.
 *
 * What this file actually does
 * ----------------------------
 * 1. At module load, sample ACTLR_EL1 on every online CPU and check
 *    that EnTSO is set everywhere.  If not, leave the prctl shim
 *    disabled -- advertising TSO support to userspace when the CPU
 *    isn't actually in TSO mode would silently corrupt FEX-Emu
 *    workloads.
 *
 * 2. If TSO is on everywhere, install a kretprobe on __arm64_sys_prctl
 *    so that PR_{GET,SET}_MEM_MODEL return the values that Hector
 *    Martin's downstream arm64 patches[1] would have returned.  This
 *    lets unmodified TSO-aware userspace (FEX-Emu, etc.) auto-detect
 *    that TSO is available and use it, without needing the out-of-tree
 *    arm64 kernel patches.
 *
 * 3. We do NOT toggle TSO per-thread.  TSO is a vCPU-wide property
 *    set by the hypervisor.  We model this to userspace as "the
 *    implementation default memory model is at least as strict as
 *    TSO", which is the exact case marcan's patch 1/4 cover letter
 *    describes:
 *
 *      PR_GET_MEM_MODEL          -> PR_SET_MEM_MODEL_DEFAULT
 *      PR_SET_MEM_MODEL_TSO      -> 0  (TSO is stricter than DEFAULT;
 *                                       the request is satisfied)
 *      PR_SET_MEM_MODEL_DEFAULT  -> 0  (the implementation default is
 *                                       already at least DEFAULT)
 *
 *    Returning DEFAULT from GET (rather than TSO) is what makes
 *    FEX-Emu's auto-detection actually call SetHardwareTSOSupport(true)
 *    -- see Source/Tools/FEXInterpreter/FEXInterpreter.cpp.
 *
 * Limitations
 * -----------
 *   - vCPUs hot-plugged after module load are not re-checked.  Linux
 *     on QEMU/HVF rarely hotplugs CPUs, so this is usually fine.
 *
 * [1] https://lwn.net/ml/linux-kernel/20240411-tso-v1-0-754f11abfbff@marcan.st/
 */

#include <linux/atomic.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/ptrace.h>
#include <linux/smp.h>

#include "tso_patch.h"

#define APPLE_TSO_BIT			(1UL << 1)

/*
 * Match Hector Martin's downstream arm64 prctl numbers byte-for-byte so
 * userspace built against his uapi headers (FEX-Emu, etc.) Just Works.
 */
#define PR_GET_MEM_MODEL		0x6d4d444c
#define PR_SET_MEM_MODEL		0x4d4d444c
#define PR_SET_MEM_MODEL_DEFAULT	0
#define PR_SET_MEM_MODEL_TSO		1

static atomic_t tso_observed_cpus;
static bool tso_globally_on;
static bool prctl_hook_installed;

/* ------------------------------------------------------------------ */
/* Per-CPU TSO observation                                            */
/* ------------------------------------------------------------------ */

/*
 * Pure observation pass.  Reads ACTLR_EL1 and counts how many CPUs
 * have EnTSO set.  We never write the register; see the top-of-file
 * comment for why.
 */
static void tso_observe_one(void *info)
{
	u64 val;

	asm volatile("mrs %0, ACTLR_EL1" : "=r"(val));

	if (val & APPLE_TSO_BIT) {
		atomic_inc(&tso_observed_cpus);
		pr_info("apple_dma: CPU%u TSO on (ACTLR_EL1=0x%llx)\n",
			smp_processor_id(), val);
	} else {
		pr_info("apple_dma: CPU%u TSO off (ACTLR_EL1=0x%llx)\n",
			smp_processor_id(), val);
	}
}

/* ------------------------------------------------------------------ */
/* prctl(PR_{GET,SET}_MEM_MODEL) shim via kretprobe on the syscall    */
/* ------------------------------------------------------------------ */

struct prctl_call {
	int  option;
	long arg2;
	long arg3;
	long arg4;
	long arg5;
};

static int prctl_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct prctl_call *pc = (struct prctl_call *)ri->data;
	struct pt_regs *user_regs = (struct pt_regs *)regs->regs[0];
	int option;

	if (!user_regs)
		return 1;

	option = (int)user_regs->regs[0];
	if (option != PR_GET_MEM_MODEL && option != PR_SET_MEM_MODEL)
		return 1; /* skip return handler — not our prctl */

	pc->option = option;
	pc->arg2 = (long)user_regs->regs[1];
	pc->arg3 = (long)user_regs->regs[2];
	pc->arg4 = (long)user_regs->regs[3];
	pc->arg5 = (long)user_regs->regs[4];
	return 0;
}

static int prctl_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct prctl_call *pc = (struct prctl_call *)ri->data;
	long ret = (long)regs->regs[0];

	/*
	 * Mainline kernels return -EINVAL for these prctls.  If something
	 * else (a livepatch, marcan's downstream patches actually present,
	 * etc.) already handled the call, leave its answer alone.
	 */
	if (ret != -EINVAL)
		return 0;

	if (!tso_globally_on)
		return 0;

	switch (pc->option) {
	case PR_GET_MEM_MODEL:
		if (pc->arg2 || pc->arg3 || pc->arg4 || pc->arg5)
			break;
		/*
		 * Advertise DEFAULT (not TSO).  TSO is the implementation
		 * default for this guest, which by marcan's semantics is
		 * reported as DEFAULT — and crucially this is what makes
		 * FEX-Emu enter its "try to enable TSO" code path.
		 */
		regs->regs[0] = PR_SET_MEM_MODEL_DEFAULT;
		break;

	case PR_SET_MEM_MODEL:
		if (pc->arg3 || pc->arg4 || pc->arg5)
			break;
		if (pc->arg2 == PR_SET_MEM_MODEL_TSO ||
		    pc->arg2 == PR_SET_MEM_MODEL_DEFAULT)
			regs->regs[0] = 0;
		break;
	}
	return 0;
}

static struct kretprobe prctl_kretprobe = {
	.kp = { .symbol_name = "__arm64_sys_prctl" },
	.entry_handler	= prctl_entry,
	.handler	= prctl_ret,
	.data_size	= sizeof(struct prctl_call),
	.maxactive	= 32,
};

/* ------------------------------------------------------------------ */
/* Public entry points                                                */
/* ------------------------------------------------------------------ */

int tso_patch_apply(void)
{
	unsigned int online = num_online_cpus();
	int observed;
	int ret;

	atomic_set(&tso_observed_cpus, 0);
	on_each_cpu(tso_observe_one, NULL, 1);
	observed = atomic_read(&tso_observed_cpus);

	if (observed != online) {
		pr_warn("apple_dma: TSO is on for only %d/%u CPUs;"
			" launch QEMU with -accel hvf,tso=on to enable"
			" it everywhere. prctl(PR_{GET,SET}_MEM_MODEL)"
			" shim disabled — userspace will see the"
			" unmodified mainline behaviour.\n",
			observed, online);
		return 0;
	}

	pr_info("apple_dma: TSO confirmed on all %u CPUs"
		" (set by hypervisor)\n", online);
	tso_globally_on = true;

	ret = register_kretprobe(&prctl_kretprobe);
	if (ret < 0) {
		pr_err("apple_dma: register_kretprobe(__arm64_sys_prctl)=%d,"
		       " prctl shim disabled (TSO still on at the CPU level)\n",
		       ret);
		return 0;
	}
	prctl_hook_installed = true;
	pr_info("apple_dma: PR_{GET,SET}_MEM_MODEL shim installed\n");
	return 0;
}

void tso_patch_revert(void)
{
	if (prctl_hook_installed) {
		unregister_kretprobe(&prctl_kretprobe);
		prctl_hook_installed = false;
		pr_info("apple_dma: PR_{GET,SET}_MEM_MODEL shim removed\n");
	}

	tso_globally_on = false;
}
