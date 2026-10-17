// SPDX-License-Identifier: GPL-2.0
/*
 * e5_pllfix: experiment for chip-level sleep on the E5 (UMS9621).
 * musb_sprd forces USB31PLLV on (PMU APB 0xa58 bit 0) at probe and never lets
 * go; chip sleep (PAD_OUT_CHIP_SLEEP) needs every PLL down.  At the last step
 * of system suspend (syscore, CPU0 only) this clears the force-on bit and logs
 * the PLL state; resume puts the bit back.  fix=0: log only.
 */
#include <linux/io.h>
#include <linux/module.h>
#include <linux/syscore_ops.h>

#define PMU_BASE	0x64910000
#define USB31PLLV_REL	0x0a58
#define FRC_ON		0x1

static bool fix = true;
module_param(fix, bool, 0644);
static void __iomem *pmu;
static u32 saved, snap[12];
static const u16 offs[12] = { 0x0a58, 0x0a5c, 0x0a20, 0x0a40, 0x0a44,
	0x0b44, 0x0b48, 0x0b4c, 0x0b50, 0x0b54, 0x0f3c, 0x0e60 };

static int pllfix_suspend(void *data)
{
	int i;

	saved = readl(pmu + USB31PLLV_REL);
	if (fix && (saved & FRC_ON))
		writel(saved & ~FRC_ON, pmu + USB31PLLV_REL);
	for (i = 0; i < 12; i++)
		snap[i] = readl(pmu + offs[i]);
	return 0;
}

static void pllfix_resume(void *data)
{
	int i;

	if (fix && (saved & FRC_ON))
		writel(readl(pmu + USB31PLLV_REL) | FRC_ON, pmu + USB31PLLV_REL);
	for (i = 0; i < 12; i++)
		pr_info("e5_pllfix suspend: %04x=%08x now %08x\n", offs[i], snap[i], readl(pmu + offs[i]));
}

static const struct syscore_ops pllfix_ops = {
	.suspend = pllfix_suspend,
	.resume = pllfix_resume,
};
static struct syscore pllfix_syscore = { .ops = &pllfix_ops };

static int __init pllfix_init(void)
{
	pmu = ioremap(PMU_BASE, 0x1000);
	if (!pmu)
		return -ENOMEM;
	register_syscore(&pllfix_syscore);
	pr_info("e5_pllfix: usb31pllv rel 0x%08x, fix=%d\n", readl(pmu + USB31PLLV_REL), fix);
	return 0;
}

static void __exit pllfix_exit(void)
{
	unregister_syscore(&pllfix_syscore);
	iounmap(pmu);
}

module_init(pllfix_init);
module_exit(pllfix_exit);
MODULE_DESCRIPTION("E5 chip sleep experiment: USB31PLLV force-on off across suspend");
MODULE_LICENSE("GPL");
