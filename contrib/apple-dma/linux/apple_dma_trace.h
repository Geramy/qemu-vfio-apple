/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef APPLE_DMA_TRACE_H
#define APPLE_DMA_TRACE_H

#include <linux/types.h>

struct apple_dma_dev;

enum apple_dma_stat_id {
	APPLE_DMA_STAT_MAP,
	APPLE_DMA_STAT_UNMAP,
	APPLE_DMA_STAT_MAP_SG,
	APPLE_DMA_STAT_UNMAP_SG,
	APPLE_DMA_STAT_ALLOC,
	APPLE_DMA_STAT_FREE,
	APPLE_DMA_STAT_COUNT,
};

#define APPLE_DMA_TRACE_OP_MAP		'M'
#define APPLE_DMA_TRACE_OP_UNMAP	'U'
#define APPLE_DMA_TRACE_OP_MAP_SG	'S'
#define APPLE_DMA_TRACE_OP_UNMAP_SG	'T'
#define APPLE_DMA_TRACE_OP_FREE		'F'

struct apple_dma_dev *apple_dma_get(void);
void apple_dma_trace_get_counts(struct apple_dma_dev *ad, u32 *maps,
				u64 *bytes, u32 *window_count);
void apple_dma_trace_get_total_counts(u32 *maps, u64 *bytes,
				      u32 *window_count);
void apple_dma_trace_get_window_config(unsigned int *shift, u64 *size);

unsigned int apple_dma_trace_stat_inc(enum apple_dma_stat_id stat);
unsigned int apple_dma_trace_stat_get(enum apple_dma_stat_id stat);
bool apple_dma_trace_should_log(unsigned int count);

void apple_dma_trace_record(struct apple_dma_dev *ad, u8 op, u64 gpa, u32 size);
void apple_dma_trace_init(void);
void apple_dma_trace_exit(void);

#endif
