// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dczid_patch - Hot-patch DC ZVA / DCZID_EL0 to prevent LLC bus errors.
 *
 * ARM64 clear_page and memset read DCZID_EL0 via MRS at runtime.
 * We replace every MRS Xn,DCZID_EL0 with MOV Xn,#0x10 so the
 * kernel always sees DZP=1 and uses plain stores instead of DC ZVA.
 *
 * Additionally, the alternatives framework replaces 4x STP with
 * DC ZVA + 3 NOPs at boot; we reverse that transformation by
 * replacing each DC ZVA + 3 NOPs with 4x STP XZR,XZR.
 *
 * This prevents LLC bus errors when DC-ZVA hits passthrough device
 * BARs mapped through HVF with Normal memory attributes.
 */

#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/smp.h>
#include <linux/string.h>
#include <asm/page.h>

#include "dczid_patch.h"

#define MRS_DCZID_MASK	0xFFFFFFE0u
#define MRS_DCZID_VAL	0xD53B00E0u	/* MRS Xn, DCZID_EL0 */
#define MOV_DZP_BASE	0xD2800200u	/* MOVZ Xn, #0x10 (DZP=1) */

#define DC_ZVA_MASK	0xFFFFFFE0u
#define DC_ZVA_VAL	0xD50B7420u	/* DC ZVA, Xt */
#define NOP_INSN	0xD503201Fu

/*
 * STP XZR, XZR, [Xn, #off] — zeros 16 bytes per instruction.
 * Four of these replace one DC ZVA (64 bytes on Apple Silicon).
 * OR in (Rn << 5) for the base register.
 */
#define STP_ZR_0	0xA9007C1Fu	/* STP XZR, XZR, [Xn] */
#define STP_ZR_16	0xA9017C1Fu	/* STP XZR, XZR, [Xn, #16] */
#define STP_ZR_32	0xA9027C1Fu	/* STP XZR, XZR, [Xn, #32] */
#define STP_ZR_48	0xA9037C1Fu	/* STP XZR, XZR, [Xn, #48] */

#define MAX_DCZID_PATCHES 64

struct dczid_patch {
	void *addr;
	u32   orig_insn;
};

static struct dczid_patch dczid_patches[MAX_DCZID_PATCHES];
static unsigned int dczid_patch_count;

typedef int (*patch_text_fn_t)(void *, u32);
typedef unsigned long (*kln_fn_t)(const char *);
static patch_text_fn_t patch_text_nosync;
static kln_fn_t kln;

static int resolve_patch_text(void)
{
	struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };
	int ret;

	ret = register_kprobe(&kp);
	if (ret < 0) {
		pr_err("apple_dma: kprobe lookup failed: %d\n", ret);
		return ret;
	}
	kln = (kln_fn_t)kp.addr;
	unregister_kprobe(&kp);

	patch_text_nosync = (patch_text_fn_t)kln("aarch64_insn_patch_text_nosync");
	if (!patch_text_nosync) {
		pr_err("apple_dma: cannot resolve aarch64_insn_patch_text_nosync\n");
		return -ENOENT;
	}
	return 0;
}

static void dczid_write_insn(void *addr, u32 insn)
{
	int ret = patch_text_nosync(addr, insn);
	if (ret)
		pr_err("apple_dma: text patch failed at %pS: %d\n", addr, ret);
}

static bool dczid_record_patch_block(u32 *addr, unsigned int count)
{
	unsigned int i;

	if (dczid_patch_count + count > MAX_DCZID_PATCHES) {
		pr_warn("apple_dma: too many text patches\n");
		return false;
	}

	for (i = 0; i < count; i++) {
		dczid_patches[dczid_patch_count].addr = addr + i;
		dczid_patches[dczid_patch_count].orig_insn = le32_to_cpu(addr[i]);
		dczid_patch_count++;
	}

	return true;
}

static const u32 stp_zr_insns[] = {
	STP_ZR_0,
	STP_ZR_16,
	STP_ZR_32,
	STP_ZR_48,
};

static int dczid_scan_func(void *start, unsigned int len)
{
	u32 *p, *end;
	int patched = 0;

	end = start + len;
	for (p = start; p < end; p++) {
		u32 insn = le32_to_cpu(*p);

		if ((insn & MRS_DCZID_MASK) != MRS_DCZID_VAL)
			continue;

		if (!dczid_record_patch_block(p, 1))
			break;
		dczid_write_insn(p, MOV_DZP_BASE | (insn & 0x1F));
		patched++;
	}
	return patched;
}

/*
 * Scan for DC ZVA instructions and replace with STP-based 64-byte zeroing.
 */
static int dczid_replace_dczva(void *start, unsigned int len)
{
	u32 *p, *end;
	int replaced = 0;

	end = (u32 *)((char *)start + len);
	for (p = (u32 *)start; p < end; p++) {
		u32 insn = le32_to_cpu(*p);
		u32 rn, stp_base;
		unsigned int i, nops;

		if ((insn & DC_ZVA_MASK) != DC_ZVA_VAL)
			continue;

		rn = insn & 0x1F;

		nops = 0;
		while (nops < ARRAY_SIZE(stp_zr_insns) - 1 && p + 1 + nops < end &&
		       le32_to_cpu(p[1 + nops]) == NOP_INSN)
			nops++;

		if (nops < 3) {
			pr_warn("apple_dma: DC ZVA at %pS (X%u) has %d trailing NOPs, need 3\n",
				p, rn, nops);
			continue;
		}

		if (!dczid_record_patch_block(p, ARRAY_SIZE(stp_zr_insns))) {
			break;
		}

		stp_base = rn << 5;

		for (i = 0; i < ARRAY_SIZE(stp_zr_insns); i++)
			dczid_write_insn(p + i, stp_zr_insns[i] | stp_base);

		pr_info("apple_dma: replaced DC ZVA at %pS (X%u) with 4x STP\n",
			p, rn);
		replaced++;
		p += 3;
	}
	return replaced;
}

static void dczid_flush_all_cpus(void *info)
{
	asm volatile("isb" ::: "memory");
}

static void dczid_scan_range(void *start, unsigned int len, int *mrs, int *zva)
{
	*mrs += dczid_scan_func(start, len);
	*zva += dczid_replace_dczva(start, len);
}

int dczid_patch_apply(void)
{
	unsigned long stext, etext;
	unsigned int text_len;
	int mrs = 0, zva = 0;
	int ret;

	ret = resolve_patch_text();
	if (ret)
		return ret;

	stext = kln("_stext");
	etext = kln("_etext");

	if (!stext || !etext || etext <= stext) {
		pr_err("apple_dma: cannot resolve _stext/_etext, "
		       "falling back to function scan\n");
		dczid_scan_range(clear_page, 256, &mrs, &zva);
		dczid_scan_range(__memset, 2048, &mrs, &zva);
	} else {
		text_len = etext - stext;
		pr_info("apple_dma: scanning kernel text %lx-%lx (%u bytes)\n",
			stext, etext, text_len);
		dczid_scan_range((void *)stext, text_len, &mrs, &zva);
	}

	if (mrs || zva)
		on_each_cpu(dczid_flush_all_cpus, NULL, 1);
	pr_info("apple_dma: patched %d MRS + %d DC-ZVA sites\n", mrs, zva);
	return 0;
}

void dczid_patch_revert(void)
{
	unsigned int i;

	for (i = 0; i < dczid_patch_count; i++)
		dczid_write_insn(dczid_patches[i].addr,
				 dczid_patches[i].orig_insn);

	if (dczid_patch_count)
		pr_info("apple_dma: restored %d text patches\n",
			dczid_patch_count);
	dczid_patch_count = 0;
}
