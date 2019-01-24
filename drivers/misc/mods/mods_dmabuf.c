/*
 * mods_dmabuf.c - This file is part of NVIDIA MODS kernel driver.
 *
 * Copyright (c) 2014-2017, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA MODS kernel driver is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * NVIDIA MODS kernel driver is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with NVIDIA MODS kernel driver.
 * If not, see <http://www.gnu.org/licenses/>.
 */

#include <linux/version.h>
#include "mods_config.h"

#ifdef MODS_HAS_DMABUF

#include <linux/dma-buf.h>
#include <linux/module.h>
#include <linux/dma-mapping.h>
#include <linux/platform_device.h>

#include "mods_internal.h"

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)
extern const struct dma_map_ops swiotlb_dma_ops;
#endif

static struct device *dummy_device;

static bool dummy_device_registered;

int esc_mods_dmabuf_get_phys_addr(struct file *filp,
				  struct MODS_DMABUF_GET_PHYSICAL_ADDRESS *op)
{
	int                        err = 0;
	struct dma_buf            *dmabuf = NULL;
	struct dma_buf_attachment *attachment = NULL;
	struct sg_table           *sgt = NULL;
	u64                        remaining_offset = op->offset;
	u64                        total_size = 0;
	u32                        total_segments = 0;
	phys_addr_t                physical_address = 0;
	unsigned int               segment_size = 0;
	struct scatterlist        *sg;
	unsigned int               sg_index;

	LOG_ENT();

	mods_debug_printk(DEBUG_MEM_DETAILED, "%s: fd=%d offs=0x%llx\n",
			  __func__, op->buf_fd, (unsigned long long)op->offset);

	dmabuf = dma_buf_get(op->buf_fd);
	if (IS_ERR_OR_NULL(dmabuf)) {
		mods_error_printk("%s: failed to get dma buf from fd %d\n",
				  __func__, op->buf_fd);
		LOG_EXT();
		return IS_ERR(dmabuf) ? PTR_ERR(dmabuf) : -EINVAL;
	}

	WARN_ON(!dummy_device_registered);
	attachment = dma_buf_attach(dmabuf, dummy_device);
	if (IS_ERR_OR_NULL(attachment)) {
		mods_error_printk("%s: failed to attach dma buf\n", __func__);
		err = IS_ERR(attachment) ? PTR_ERR(attachment) : -EFAULT;
		goto buf_attach_fail;
	}

	sgt = dma_buf_map_attachment(attachment, DMA_BIDIRECTIONAL);
	if (IS_ERR_OR_NULL(sgt)) {
		mods_error_printk("%s: failed to map dma buf\n", __func__);
		err = IS_ERR(sgt) ? PTR_ERR(sgt) : -EFAULT;
		goto buf_map_fail;
	}

	for_each_sg(sgt->sgl, sg, sgt->nents, sg_index) {
		total_size += sg->length;
		++total_segments;
		if (remaining_offset >= sg->length) {
			/* haven't reached segment yet, or empty sg */
			remaining_offset -= sg->length;
		} else if (segment_size == 0) {
			/* first sg in segment */
			physical_address = sg_phys(sg) + remaining_offset;
			segment_size = sg->length - remaining_offset;
			remaining_offset = 0;
		} else if (sg_phys(sg) == physical_address + segment_size) {
			/* contiguous sg; append to segment */
			segment_size += sg->length;
		} else {
			/* discontiguous sg; end segment */
			break;
		}
	}

	mods_debug_printk(DEBUG_MEM_DETAILED, "%s: traversed %u segments, 0x%llx size\n",
			  __func__, total_segments,
			  (unsigned long long) total_size);

	if (segment_size == 0) {
		mods_error_printk("%s: offset 0x%llx exceeds allocation size 0x%llx\n",
				  __func__, (unsigned long long)op->offset,
				  total_size);
		err = -EINVAL;
	} else {
		op->physical_address = physical_address;
		op->segment_size = segment_size;
	}

	dma_buf_unmap_attachment(attachment, sgt, DMA_BIDIRECTIONAL);

buf_map_fail:
	dma_buf_detach(dmabuf, attachment);

buf_attach_fail:
	dma_buf_put(dmabuf);

	LOG_EXT();
	return err;
}

static int mods_dmabuf_probe(struct platform_device *pdev)
{
	dma_set_mask(&pdev->dev, DMA_BIT_MASK(39));
	dummy_device = &pdev->dev;

	dummy_device_registered = true;
	return 0;
}

static int mods_dmabuf_remove(struct platform_device *pdev)
{
	return 0;
}

static const struct of_device_id of_ids[] = {
	{ .compatible = "nvidia,mods_test" },
	{ }
};

static struct platform_driver mods_dummy_driver = {
	.probe  = mods_dmabuf_probe,
	.remove = mods_dmabuf_remove,
	.driver = {
		.name   = "nvidia_mods_dummy_driver",
		.owner  = THIS_MODULE,
		.of_match_table = of_ids,
	},
};

int mods_init_dmabuf(void)
{
	return platform_driver_register(&mods_dummy_driver);
}

void mods_exit_dmabuf(void)
{
	platform_driver_unregister(&mods_dummy_driver);
}

#endif
