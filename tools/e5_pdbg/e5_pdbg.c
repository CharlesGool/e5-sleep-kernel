// SPDX-License-Identifier: GPL-2.0
/*
 * e5_pdbg: print TF-A's sleep-debug snapshot (the vendor sprd_pdbg data:
 * SLP_STATE, EB_INFO, PD_INFO, DEEP/LIGHT counters) at the last step of
 * system suspend, with only CPU0 left -- the same moment the vendor driver
 * prints "PDBG DEEP SLEEP START".  Read-only: one SIP SMC per item.
 * Also /proc/e5_pdbg for the current values.
 */
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/sprd_sip_svc.h>
#include <linux/syscore_ops.h>

#define N_TYPES 6
static const char *const names[N_TYPES] = {
	"SLP_STATE", "EB_INFO", "PD_INFO", "DEEP_CNT", "LIGHT_CNT", "LPC_INFO" };
static struct sprd_sip_svc_pwr_ops *ops;
static u64 snap[N_TYPES][4];
static u64 snap_ret[N_TYPES];
static bool have_snap;

static void grab(u64 v[N_TYPES][4], u64 *ret)
{
	int i;

	for (i = 0; i < N_TYPES; i++)
		ret[i] = ops->get_pdbg_info(i, 0, &v[i][0], &v[i][1], &v[i][2], &v[i][3]);
}

static void print_cnt(struct seq_file *m, const char *tag, u64 *v)
{
	u8 *p = (u8 *)v;
	int n = p[30], i;
	char buf[160];
	int len = 0;

	if (n > 15)
		n = 15;
	for (i = 0; i < n; i++)
		len += scnprintf(buf + len, sizeof(buf) - len, "%5d,", p[2 * i] | (p[2 * i + 1] << 8));
	if (m)
		seq_printf(m, "%s %-9s %s\n", tag, "CNT", buf);
	else
		pr_info("%s CNT %s\n", tag, buf);
}

static void show(struct seq_file *m, const char *tag, u64 v[N_TYPES][4], u64 *ret)
{
	int i;

	for (i = 0; i < N_TYPES; i++) {
		if (m)
			seq_printf(m, "%s %-9s ret=%llx %016llx %016llx %016llx %016llx\n", tag, names[i],
				   ret[i], v[i][0], v[i][1], v[i][2], v[i][3]);
		else
			pr_info("%s %-9s ret=%llx %016llx %016llx %016llx %016llx\n", tag, names[i],
				ret[i], v[i][0], v[i][1], v[i][2], v[i][3]);
	}
	print_cnt(m, tag, v[3]);
}

static int e5_pdbg_suspend(void *data)
{
	grab(snap, snap_ret);
	have_snap = true;
	return 0;
}

static void e5_pdbg_resume(void *data)
{
	if (have_snap)
		show(NULL, "e5_pdbg suspend:", snap, snap_ret);
}

static const struct syscore_ops e5_pdbg_syscore_ops = {
	.suspend = e5_pdbg_suspend,
	.resume = e5_pdbg_resume,
};

static struct syscore e5_pdbg_syscore = {
	.ops = &e5_pdbg_syscore_ops,
};

static int e5_pdbg_proc_show(struct seq_file *m, void *v)
{
	u64 now[N_TYPES][4], ret[N_TYPES];

	grab(now, ret);
	show(m, "now", now, ret);
	if (have_snap)
		show(m, "suspend", snap, snap_ret);
	return 0;
}

static int __init e5_pdbg_init(void)
{
	struct sprd_sip_svc_handle *h = sprd_sip_svc_get_handle();

	if (!h || !h->pwr_ops.get_pdbg_info)
		return -ENODEV;
	ops = &h->pwr_ops;
	proc_create_single("e5_pdbg", 0444, NULL, e5_pdbg_proc_show);
	register_syscore(&e5_pdbg_syscore);
	return 0;
}

static void __exit e5_pdbg_exit(void)
{
	unregister_syscore(&e5_pdbg_syscore);
	remove_proc_entry("e5_pdbg", NULL);
}

module_init(e5_pdbg_init);
module_exit(e5_pdbg_exit);
MODULE_LICENSE("GPL");
