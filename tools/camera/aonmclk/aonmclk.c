// SPDX-License-Identifier: GPL-2.0
/*
 * aonmclk, route and drive the sensor's master clock by hand.
 *
 * the board wires sensor mclk to gpio100 (function cam_aon, which sm8550
 * spells cam_aon_mclk4), but nothing in the dt claimed it, so it sat as a
 * plain gpio with no clock behind it. that is why the sensor never answered
 * on the cci bus while its eeprom did. this muxes the pin and enables one
 * camcc mclk so a bus scan can say whether the sensor wakes up. test
 * scaffolding, superseded by the sensor node in patch 0006.
 *
 *   insmod aonmclk.ko mclk=4 rate=19200000
 */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/clk.h>
#include <linux/of.h>
#include <linux/clk-provider.h>

#define TLMM_BASE	0x0f100000
#define TLMM_PIN_CTL(p)	(TLMM_BASE + (p) * 0x1000)
#define MCLK_PIN	100

/*
 * qcom,x1e80100-camcc.h: CAM_CC_MCLK0_CLK is 71 and they go up in pairs of
 * (branch, src), so MCLK<n> branch = 71 + 2n and its RCG = 72 + 2n.
 * gpio100's alt function is "cam_aon", which sm8550 spells "cam_aon_mclk4" -
 * so this pin is MCLK4.
 */
static int mclk = 4;
module_param(mclk, int, 0444);

static unsigned long rate = 19200000;
module_param(rate, ulong, 0444);

static struct clk *held;
static struct clk *src;
static void __iomem *ctl;
static u32 saved;

static int __init aon_init(void)
{
	struct of_phandle_args args = {};
	struct device_node *np;
	u32 val;
	int ret;

	np = of_find_compatible_node(NULL, NULL, "qcom,x1e80100-camcc");
	if (!np) {
		pr_err("aonmclk: no camcc node\n");
		return -ENODEV;
	}

	args.np = np;
	args.args_count = 1;
	/* the rate has to be set on the RCG; the branch just gates it */
	args.args[0] = 72 + 2 * mclk;		/* CAM_CC_MCLK<n>_CLK_SRC */
	src = of_clk_get_from_provider(&args);
	if (!IS_ERR(src)) {
		ret = clk_set_rate(src, rate);
		if (ret)
			pr_warn("aonmclk: src set_rate %lu failed: %d\n", rate, ret);
		ret = clk_prepare_enable(src);
		if (ret)
			pr_warn("aonmclk: src enable failed: %d\n", ret);
		pr_info("aonmclk: MCLK%d_CLK_SRC now %lu Hz\n", mclk, clk_get_rate(src));
	} else {
		pr_warn("aonmclk: no MCLK%d_CLK_SRC\n", mclk);
		src = NULL;
	}

	args.args[0] = 71 + 2 * mclk;		/* CAM_CC_MCLK<n>_CLK */
	held = of_clk_get_from_provider(&args);
	of_node_put(np);
	if (IS_ERR(held)) {
		pr_err("aonmclk: MCLK%d not available: %ld\n", mclk, PTR_ERR(held));
		return PTR_ERR(held);
	}

	ret = clk_set_rate(held, rate);
	if (ret)
		pr_warn("aonmclk: branch set_rate %lu failed: %d\n", rate, ret);

	ret = clk_prepare_enable(held);
	if (ret) {
		pr_err("aonmclk: enable failed: %d\n", ret);
		clk_put(held);
		return ret;
	}

	/* mux gpio100 to its first alt function (cam_aon), 16 mA, no pull */
	ctl = ioremap(TLMM_PIN_CTL(MCLK_PIN), 4);
	if (!ctl) {
		clk_disable_unprepare(held);
		clk_put(held);
		return -ENOMEM;
	}
	saved = readl(ctl);
	val = (1 << 2) | (7 << 6);
	writel(val, ctl);

	pr_info("aonmclk: MCLK%d at %lu Hz, gpio100 ctl 0x%08x -> 0x%08x\n",
		mclk, clk_get_rate(held), saved, readl(ctl));
	return 0;
}

static void __exit aon_exit(void)
{
	if (ctl) {
		writel(saved, ctl);
		iounmap(ctl);
	}
	if (!IS_ERR_OR_NULL(held)) {
		clk_disable_unprepare(held);
		clk_put(held);
	}
	if (!IS_ERR_OR_NULL(src)) {
		clk_disable_unprepare(src);
		clk_put(src);
	}
	pr_info("aonmclk: restored\n");
}

module_init(aon_init);
module_exit(aon_exit);
MODULE_LICENSE("GPL");
