// SPDX-License-Identifier: GPL-2.0-or-later

#include <linux/debugfs.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#include "apple_dma_trace.h"

struct dma_trace_entry {
	u64 timestamp_ns;
	u64 gpa;
	u32 size;
	u8  op;
	u32 active_maps;
	u64 active_bytes;
};

#define TRACE_RING_SIZE		(1 << 18)	/* 256K entries */
#define TRACE_RING_MASK		(TRACE_RING_SIZE - 1)

static struct dma_trace_entry *trace_ring;
static unsigned int trace_head;		/* next write index */
static unsigned int trace_count;	/* entries written (saturates at RING_SIZE) */
static u32 trace_hwm_maps;		/* high-water mark: map count */
static u64 trace_hwm_bytes;		/* high-water mark: mapped bytes */
static DEFINE_SPINLOCK(trace_lock);

static struct dentry *trace_debugfs_dir;
static unsigned int trace_stats[APPLE_DMA_STAT_COUNT];

unsigned int apple_dma_trace_stat_inc(enum apple_dma_stat_id stat)
{
	return ++trace_stats[stat];
}

unsigned int apple_dma_trace_stat_get(enum apple_dma_stat_id stat)
{
	return trace_stats[stat];
}

bool apple_dma_trace_should_log(unsigned int count)
{
	return count <= 8 || (count % 64) == 0;
}

void apple_dma_trace_record(struct apple_dma_dev *ad, u8 op, u64 gpa, u32 size)
{
	struct dma_trace_entry *e;
	unsigned long flags;
	u32 maps;
	u64 bytes;

	if (!trace_ring)
		return;

	apple_dma_trace_get_counts(ad, &maps, &bytes, NULL);

	spin_lock_irqsave(&trace_lock, flags);
	e = &trace_ring[trace_head & TRACE_RING_MASK];
	e->timestamp_ns = ktime_get_ns();
	e->gpa = gpa;
	e->size = size;
	e->op = op;
	e->active_maps = maps;
	e->active_bytes = bytes;
	trace_head++;
	if (trace_count < TRACE_RING_SIZE)
		trace_count++;
	if (maps > trace_hwm_maps)
		trace_hwm_maps = maps;
	if (bytes > trace_hwm_bytes)
		trace_hwm_bytes = bytes;
	spin_unlock_irqrestore(&trace_lock, flags);
}

static void *trace_seq_start(struct seq_file *m, loff_t *pos)
{
	if (*pos == 0)
		return SEQ_START_TOKEN;
	if (*pos > trace_count)
		return NULL;
	return (void *)(unsigned long)(*pos);
}

static void *trace_seq_next(struct seq_file *m, void *v, loff_t *pos)
{
	(*pos)++;
	if (*pos > trace_count)
		return NULL;
	return (void *)(unsigned long)(*pos);
}

static void trace_seq_stop(struct seq_file *m, void *v)
{
}

static int trace_seq_show(struct seq_file *m, void *v)
{
	unsigned int idx, start;
	struct dma_trace_entry *e;

	if (v == SEQ_START_TOKEN) {
		seq_puts(m, "timestamp_ns,op,gpa_hex,size,active_maps,active_bytes\n");
		return 0;
	}

	spin_lock_irq(&trace_lock);
	start = trace_count >= TRACE_RING_SIZE ? trace_head : 0;
	idx = (start + (unsigned long)v - 1) & TRACE_RING_MASK;
	e = &trace_ring[idx];
	seq_printf(m, "%llu,%c,0x%llx,%u,%u,%llu\n",
		   e->timestamp_ns, e->op, e->gpa, e->size,
		   e->active_maps, e->active_bytes);
	spin_unlock_irq(&trace_lock);
	return 0;
}

static const struct seq_operations trace_seq_ops = {
	.start = trace_seq_start,
	.next  = trace_seq_next,
	.stop  = trace_seq_stop,
	.show  = trace_seq_show,
};

static int trace_open(struct inode *inode, struct file *file)
{
	return seq_open(file, &trace_seq_ops);
}

static const struct file_operations trace_fops = {
	.open    = trace_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = seq_release,
};

static ssize_t trace_reset_write(struct file *file, const char __user *buf,
				 size_t count, loff_t *ppos)
{
	unsigned long flags;

	spin_lock_irqsave(&trace_lock, flags);
	trace_head = 0;
	trace_count = 0;
	trace_hwm_maps = 0;
	trace_hwm_bytes = 0;
	spin_unlock_irqrestore(&trace_lock, flags);
	return count;
}

static const struct file_operations trace_reset_fops = {
	.write = trace_reset_write,
};

static int trace_snapshot_show(struct seq_file *m, void *v)
{
	unsigned int window_shift;
	u32 cur_maps, window_count;
	u64 cur_bytes, window_size;

	apple_dma_trace_get_total_counts(&cur_maps, &cur_bytes, &window_count);
	apple_dma_trace_get_window_config(&window_shift, &window_size);

	seq_printf(m, "current_maps: %u\n", cur_maps);
	seq_printf(m, "current_bytes: %llu\n", cur_bytes);
	seq_printf(m, "hwm_maps: %u\n", trace_hwm_maps);
	seq_printf(m, "hwm_bytes: %llu\n", trace_hwm_bytes);
	seq_printf(m, "trace_entries: %u\n", trace_count);
	seq_printf(m, "trace_capacity: %u\n", TRACE_RING_SIZE);
	seq_printf(m, "stat_map: %u\n",
		   apple_dma_trace_stat_get(APPLE_DMA_STAT_MAP));
	seq_printf(m, "stat_unmap: %u\n",
		   apple_dma_trace_stat_get(APPLE_DMA_STAT_UNMAP));
	seq_printf(m, "stat_map_sg: %u\n",
		   apple_dma_trace_stat_get(APPLE_DMA_STAT_MAP_SG));
	seq_printf(m, "stat_unmap_sg: %u\n",
		   apple_dma_trace_stat_get(APPLE_DMA_STAT_UNMAP_SG));
	seq_printf(m, "stat_alloc: %u\n",
		   apple_dma_trace_stat_get(APPLE_DMA_STAT_ALLOC));
	seq_printf(m, "stat_free: %u\n",
		   apple_dma_trace_stat_get(APPLE_DMA_STAT_FREE));
	seq_printf(m, "window_shift: %u\n", window_shift);
	seq_printf(m, "window_size: %llu\n", window_size);
	seq_printf(m, "window_count: %u\n", window_count);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(trace_snapshot);

void apple_dma_trace_init(void)
{
	trace_ring = kvmalloc_array(TRACE_RING_SIZE,
				    sizeof(struct dma_trace_entry),
				    GFP_KERNEL | __GFP_ZERO);
	if (!trace_ring) {
		pr_warn("apple_dma: failed to allocate trace ring buffer\n");
		return;
	}

	trace_debugfs_dir = debugfs_create_dir("apple_dma", NULL);
	debugfs_create_file("trace", 0444, trace_debugfs_dir, NULL,
			    &trace_fops);
	debugfs_create_file("reset", 0200, trace_debugfs_dir, NULL,
			    &trace_reset_fops);
	debugfs_create_file("snapshot", 0444, trace_debugfs_dir, NULL,
			    &trace_snapshot_fops);
}

void apple_dma_trace_exit(void)
{
	debugfs_remove_recursive(trace_debugfs_dir);
	trace_debugfs_dir = NULL;
	kvfree(trace_ring);
	trace_ring = NULL;
}
