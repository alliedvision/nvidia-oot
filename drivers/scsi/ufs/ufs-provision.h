/* SPDX-License-Identifier: GPL-2.0-only
 */
// Copyright (c) 2015-2023 NVIDIA CORPORATION & AFFILIATES.  All rights reserved.

#ifndef _UFS_PROVISION_H
#define _UFS_PROVISION_H

#include <linux/kernel.h>
#include <linux/module.h>
#include <drivers-private/scsi/ufs/ufshcd.h>

#ifdef CONFIG_DEBUG_FS
#include <linux/debugfs.h>
void debugfs_provision_init(struct ufs_hba *hba, struct dentry *device_root);
void debugfs_provision_exit(struct ufs_hba *hba);
#else
static inline void debugfs_provision_init(struct ufs_hba *hba, struct dentry *device_root)
{
	return;
}
static inline void debugfs_provision_exit(struct ufs_hba *hba)
{
	return;
}
#endif

#endif
