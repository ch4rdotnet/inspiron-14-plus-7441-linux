// SPDX-License-Identifier: GPL-2.0
/*
 * mmiopeek, read the first few words of an mmio aperture.
 *
 * tells a live cci aperture (HW_VERSION 0x10070000) from some other block
 * without describing it in dt and rebuilding a kernel first. only safe while
 * the surrounding clocks and power domain are already on, 0x0ac14000 for one
 * is unmapped and reading it raises a synchronous external abort.
 *
 *   insmod mmiopeek.ko addr=0x0ac15000 words=4    (never loads, prints and returns -EAGAIN)
 */
#include <linux/module.h>
#include <linux/io.h>

static unsigned long addr;
module_param(addr, ulong, 0444);

static int words = 4;
module_param(words, int, 0444);

static int __init peek_init(void)
{
	void __iomem *p;
	int i;

	if (!addr)
		return -EINVAL;

	p = ioremap(addr, words * 4 + 0x10);
	if (!p)
		return -ENOMEM;

	{
		int nz = 0;
		u32 v;

		for (i = 0; i < words; i++) {
			v = readl(p + i * 4);
			if (v) {
				if (nz < 8)
					pr_info("mmiopeek: 0x%lx + 0x%04x = 0x%08x\n",
						addr, i * 4, v);
				nz++;
			}
		}
		pr_info("mmiopeek: 0x%lx scanned %d words, %d non-zero\n",
			addr, words, nz);
	}

	iounmap(p);
	return -EAGAIN;	/* never actually load */
}
module_init(peek_init);
MODULE_LICENSE("GPL");
