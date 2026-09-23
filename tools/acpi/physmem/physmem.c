// SPDX-License-Identifier: GPL-2.0
/*
 * physmem, a debugfs window onto physical memory.
 *
 * /dev/mem refuses reads of system ram under CONFIG_STRICT_DEVMEM, which
 * blocks reading the acpi tables uefi left in efi reclaim memory when the
 * kernel booted from dt and never parsed them. this exposes the same thing
 * without the ram check, read at file offset n returns physical byte n.
 * root only via debugfs, debugging aid only.
 */
#include <linux/module.h>
#include <linux/debugfs.h>
#include <linux/io.h>
#include <linux/uaccess.h>
#include <linux/mm.h>

static ssize_t physmem_read(struct file *f, char __user *ubuf,
			    size_t count, loff_t *ppos)
{
	phys_addr_t pa = (phys_addr_t)*ppos;
	size_t chunk;
	void *va;

	/* keep each mapping inside one page so partial pages are simple */
	chunk = min(count, (size_t)(PAGE_SIZE - offset_in_page(pa)));
	if (!chunk)
		return 0;

	va = memremap(pa, chunk, MEMREMAP_WB);
	if (!va)
		return -EIO;

	if (copy_to_user(ubuf, va, chunk)) {
		memunmap(va);
		return -EFAULT;
	}
	memunmap(va);

	*ppos += chunk;
	return chunk;
}

static const struct file_operations physmem_fops = {
	.owner	= THIS_MODULE,
	.read	= physmem_read,
	.llseek	= default_llseek,
};

static struct dentry *physmem_file;

static int __init physmem_init(void)
{
	physmem_file = debugfs_create_file("physmem", 0400, NULL, NULL,
					   &physmem_fops);
	return 0;
}

static void __exit physmem_exit(void)
{
	debugfs_remove(physmem_file);
}

module_init(physmem_init);
module_exit(physmem_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("debugfs window onto physical memory");
