# cpufreq: only one of three perf domains got a policy

two separate problems, and it is worth keeping them apart. the first is that
`scmi-cpufreq` never loads on a stock fedora kernel, so there is no cpufreq at
all. the second is a real kernel bug that leaves six of ten cores without a
policy even once the driver is loaded. patch 0001 fixes the second, a config
change in `config/kernel-local` fixes the first.

machine: dell inspiron 14 plus 7441 (`dell,inspiron-14-plus-7441`), snapdragon x,
fedora 44, kernel 7.1.13, `scmi-cpufreq`.

## part one: the driver never loads

no cpufreq policy is registered at all on a stock kernel:

```
/sys/devices/system/cpu/cpufreq/          -> empty
/sys/devices/system/cpu/cpu0/cpufreq/     -> does not exist
```

scmi itself is healthy and the cpu nodes are wired for it:

```
arm-scmi arm-scmi.0.auto: SCMI Protocol v2.0 'Qualcomm:' Firmware version 0x20000
scmi-perf-domain scmi_dev.3: Initialized 3 performance domains

/proc/device-tree/cpus/cpu@0/power-domain-names = "psci", "perf"
```

the scmi bus has exactly one perf device, and it belongs to the built in
`scmi-perf-domain`:

```
scmi_dev.3:13:perf  ->  driver scmi-perf-domain     (CONFIG_ARM_SCMI_PERF_DOMAIN=y)
```

`modinfo scmi-cpufreq` prints no `alias` lines whatsoever, and neither does any
other scmi module driver (`scmi-hwmon`, `scmi_iio`, `arm_scmi_powercap`,
`scmi-regulator`). two reasons, both structural:

- `scmi-cpufreq.c` does declare `MODULE_DEVICE_TABLE(scmi, scmi_id_table)`, but
  `scripts/mod/file2alias.c` has no scmi handler. modpost cannot turn that table
  into an alias, so the macro is a silent no-op.
- even with an alias it would not help. scmi devices are created on driver
  request, `scmi_protocol_device_request()` runs when a driver registers.
  observed directly, `scmi_dev.4:13:cpufreq` did not exist until
  `modprobe scmi-cpufreq`. udev would never have a device to match against.

so this cannot be fixed by patching `scmi-cpufreq`. two ways round it.

### method a, modules-load.d (no rebuild)

`/etc/modules-load.d/99-scmi-cpufreq.conf` containing `scmi-cpufreq`. works with
fedora's stock `CONFIG_ARM_SCMI_CPUFREQ=m`, useful for getting cpufreq back on a
stock kernel. `tools/cpufreq/try-cpufreq.sh --persist` writes it. downside, it is a
config file that has to travel with the machine, and it loads late in boot
rather than at driver registration time.

### method b, build it in (preferred)

`config/kernel-local`:

```
CONFIG_ARM_SCMI_CPUFREQ=y
```

fedora already builds the sibling drivers in (`ARM_SCMI_PERF_DOMAIN=y`,
`ARM_SCMI_POWER_DOMAIN=y`), so this is consistent, not a hack. builtin means it
registers at boot, which is exactly what the scmi device model wants, and
method a becomes unnecessary. `CONFIG_CPU_FREQ` and `CONFIG_PM_OPP` need no
change, both are `bool`, both already `=y`, and `ARM_SCMI_CPUFREQ` selects
`PM_OPP` anyway. if method b is used, delete the modules-load.d file, harmless
if left but it will try to modprobe something that is no longer a module.

"build `ARM_SCMI_CPUFREQ=y` like the other two scmi drivers" is a much easier
bug report to fedora than "the scmi device model cannot autoload modular
drivers", and fixes it for everyone.

## part two: the turbo bug

with the driver loaded by hand, only `policy0` exists, covering cpus 0 to 3.
cpus 4 to 6 and 8 to 10 get no `cpufreq` directory at all. nothing is logged.

```
scmi_dev.3:13:perf     -> scmi-perf-domain
scmi_dev.4:13:cpufreq  -> scmi-cpufreq        (appears only once the module is loaded)

policy0: driver=scmi gov=schedutil  cpus=[0 1 2 3]
         710400 - 3417600 kHz, 13 OPPs
cooling device: cpufreq-cpu0        (the first cpu throttling path this machine has had)
```

### root cause

the scmi firmware reports a bogus `sustained_freq_khz` for perf domains NCC1 and
NCC2, below their lowest opp. `scmi_dvfs_device_opps_add()` then flags every opp
in those domains as turbo:

```c
/* All OPPs above the sustained frequency are treated as turbo */
data.turbo = freq > dom->sustained_freq_khz * 1000UL;
```

`cpufreq_frequency_table_cpuinfo()` skips boost-flagged entries and fails if
none survive:

```c
cpufreq_for_each_valid_entry_idx(pos, table, i) {
        freq = pos->frequency;
        if ((!cpufreq_boost_enabled() || !policy->boost_enabled)
            && (pos->flags & CPUFREQ_BOOST_FREQ))
                continue;                       /* every entry skipped */
        ...
}
...
if (min_freq == ~0)
        return -EINVAL;
```

`cpufreq_policy_online()` drops the policy on that error with no message:

```c
ret = cpufreq_table_validate_and_sort(policy);
if (ret)
        goto out_offline_policy;        /* silent */
```

### it cannot be worked around by enabling boost

there is a chicken and egg problem in the core. during validation
`policy->boost_enabled` is still 0 for a new policy, and the two places that
would set it both run later:

- `policy->boost_supported` is set in `cpufreq_table_validate_and_sort()`, after
  `cpufreq_frequency_table_cpuinfo()` has already returned `-EINVAL`.
- `policy->boost_enabled` is set in `cpufreq_online()` at the
  `policy_set_boost()` call, after `cpufreq_policy_online()` returns, which it
  never does.

so `echo 1 > /sys/devices/system/cpu/cpufreq/boost` does not help. a perf domain
whose opps are all flagged turbo can never get a policy, whatever the global
boost setting.

### evidence

kretprobes on the relevant functions while reloading the module
(`tools/cpufreq/try-cpufreq.sh --trace`):

```
online:     cpu=0
opp_table:  scmi_cpufreq_init <- dev_pm_opp_init_cpufreq_table            ret=0
qos_add:    scmi_cpufreq_init <- freq_qos_add_request                     ret=0
ft_cpuinfo: cpufreq_table_validate_and_sort <- ..._table_cpuinfo          ret=0
validate:   cpufreq_policy_online <- cpufreq_table_validate_and_sort      ret=0
online_ret: cpufreq_online <- cpufreq_policy_online                       ret=0

online:     cpu=4
opp_table:  scmi_cpufreq_init <- dev_pm_opp_init_cpufreq_table            ret=0
qos_add:    scmi_cpufreq_init <- freq_qos_add_request                     ret=0
ft_cpuinfo: cpufreq_table_validate_and_sort <- ..._table_cpuinfo          ret=-22
validate:   cpufreq_policy_online <- cpufreq_table_validate_and_sort      ret=-22
online_ret: cpufreq_online <- cpufreq_policy_online                       ret=-22
```

identical `-22` for cpus 5, 6, 8, 9, 10. the opp table is built successfully in
every case (`dev_pm_opp_init_cpufreq_table` returns 0), it is the core's
validation that rejects it.

corroborating, all three domains expose the same 13 opps, 710400 to 3417600 khz,
and domain 0's boost list is empty while domains 1 and 2 must be entirely boost:

```
$ cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
710400 806400 998400 1190400 1440000 1670400 1920000 2188800 2515200 2707200 2976000 3206400 3417600
$ cat /sys/devices/system/cpu/cpufreq/policy0/scaling_boost_frequencies
                      # empty, nothing above sustained_freq for NCC0
$ cat /sys/devices/system/cpu/cpufreq/boost
0
```

so NCC0 reports `sustained_freq_khz >= 3417600`, while NCC1 and NCC2 report
something below 710400.

`tools/cpufreq/verify-turbo.sh` confirmed the diagnosis before any kernel was built, by
probing `dev_pm_opp_add_dynamic()` and reading the `turbo` flag straight out of
the `struct dev_pm_opp_data` the scmi perf layer passes in. all 13 opps are
added with `turbo=0` for cpu0 and `turbo=1` for every cpu in NCC1 and NCC2. the
raw dynamic_debug output from the earlier, wider net is in
`docs/evidence/cpufreq-dynamic-debug.txt` and
`docs/evidence/cpufreq-dynamic-debug-2.txt`.

### ruled out along the way

- not the two never booting cores (cpu7, cpu11, `psci ... -22`). taking cpu3
  offline to give domain 0 the same present but not online shape did not break
  policy0 (`tools/cpufreq/try-cpufreq.sh` grew a `--test-theory` mode for exactly this,
  since dropped).
- not `scmi-perf-domain` holding the domains, it coexists fine.
  `scmi_dev.3:13:perf` and `scmi_dev.4:13:cpufreq` bind simultaneously.
- not a driver side failure, `scmi_cpufreq_init()` returns 0 in all cases.
  `scmi-cpufreq.c` has zero dynamic debug sites, and cpufreq.c's own
  "initialization failed" pr_debug did not fire.

### the fix

`patches/out/scmi/0001-firmware-arm_scmi-perf-ignore-an-implausible-sustain.patch`,
`drivers/firmware/arm_scmi/perf.c`, +28 -6, the version sent to the arm_scmi
maintainers. a sustained frequency below the lowest opp carries no information
and acting on it makes the whole domain unusable, so it's ignored in that case
and the domain is treated as having no turbo opps. the opp frequency
calculation moves into a helper so the lowest opp can be found first:

```diff
+	for (idx = 0; idx < dom->opp_count; idx++)
+		lowest_hz = min(lowest_hz, scmi_perf_opp_freq(dom, idx));
+
+	sustained_hz = dom->sustained_freq_khz * 1000UL;
+	if (dom->opp_count && sustained_hz < lowest_hz) {
+		dev_warn_once(dev, FW_BUG
+			      "[%d][%s]: sustained freq %lu Hz below lowest OPP %lu Hz, ignored\n",
+			      domain, dom->info.name, sustained_hz, lowest_hz);
+		sustained_hz = ULONG_MAX;
+	}
+
 	for (idx = 0; idx < dom->opp_count; idx++) {
-		...
+		freq = scmi_perf_opp_freq(dom, idx);
 
 		/* All OPPs above the sustained frequency are treated as turbo */
-		data.turbo = freq > dom->sustained_freq_khz * 1000UL;
+		data.turbo = freq > sustained_hz;
```

no-op on hardware that reports a sane value. a sustained frequency equal to the
lowest opp is left alone, it already leaves that opp non turbo. the failure was
silent before, so the ignored value now gets a `FW_BUG` warning in the kernel
log, once.

a second, independent hardening would be in
`cpufreq_frequency_table_cpuinfo()`: if skipping boost entries leaves the table
empty, fall back to counting them rather than returning `-EINVAL`, since the
policy cannot enable boost before it exists. this kernel already carries scmi
quirks for this platform (`quirk_perf_level_get_fc_force`,
`quirk_clock_rates_triplet_out_of_spec`), so a quirk entry would be an equally
reasonable home for the workaround.

### status: built and working

in `kernel-7.1.13-200.dellfix.fc44` all three perf domains get a policy:

```
policy0: cpus=[0 1 2 3]  drv=scmi gov=schedutil  cur=2976000 kHz
policy4: cpus=[4 5 6]    drv=scmi gov=schedutil  cur=998400 kHz
policy8: cpus=[8 9 10]   drv=scmi gov=schedutil  cur=806400 kHz
```

all three report an empty `scaling_boost_frequencies`, confirming nothing is
flagged turbo any more, and each exposes the full 13 frequency table. the
clusters sit at different frequencies under light load, so schedutil is scaling
them independently.

the machine also gained its first cpu throttling path, `cpufreq-cpu0`,
`cpufreq-cpu4` and `cpufreq-cpu8` cooling devices, where before only the gpu
devfreq and the pcie link existed. measured idle draw fell from ~12 w to ~8 w
(`scripts/powerlog.sh`, unplugged).

worth sending to `linux-pm` and `linux-arm-kernel`. the bug is still present in
current upstream master, `perf.c` is byte identical to v7.1.13, the reproducer
is clean, and the fix is one hunk. see [upstreaming.md](upstreaming.md).

## a note on the firmware

cluster 0 is the one with a different midr variant (`0x512f0011` against
`0x511f0011`), and it is also the only domain reporting a valid sustained
frequency. that looks like perf attributes populated properly for the prime
cluster and not the others on this bin. the device tree is not the mechanism,
scmi is a firmware to kernel interface, so what the dt claims cannot change
what scmi reports. see the soc note in [status.md](status.md).
