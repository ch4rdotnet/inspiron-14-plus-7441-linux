# hard hangs

status: **four hard hangs so far, three of them on the patched kernel within
two days.** none left a kernel message. crash capture was not turned on after
the first one, so up to five minutes of log is missing from each. this file is
the record, the hypotheses, and what to do about it. `scripts/hang-report.sh`
pulls the same information out of the journal after the next one.

## the record

times are local. the journal's last line is up to five minutes before the
actual freeze (journald's default sync interval).

| | when | kernel | up for | journal ends | what was going on | last thing logged |
|---|---|---|---|---|---|---|
| 1 | 2026-09-07 ~21:19 | 7.1.13-200 stock, plus the dell firmware | ~50 min | 21:04:36 | about 15 minutes of video playback in firefox. no cpufreq yet (six cores pinned high), gpu live for under an hour | a `vm.laptop_mode is deprecated` notice. that journal has since rotated away |
| 2 | 2026-09-09 01:35 to 01:40 | `dellfix` | 35 min | 01:34:58 | resumed from a one minute deep suspend at 01:22:41. at 01:31:03 chronyd logged `Forward time jump detected!` with no suspend in between. fingerprint unlock at 01:33 | `fprintd.service: Deactivated successfully`, then irqbalance noise |
| 3 | 2026-09-10 00:05 to 00:10 | `dellfix` | 4 h | 00:04:57 | four deep suspend cycles, the last resume at 23:49:14. steam, firefox and prism launcher (a java minecraft launcher) open, abrt caught a java crash at 23:55:27. waydroid had been installed at 21:34 and its binder errors fill the log from 21:44 to the end | binder spam |
| 4 | 2026-09-10 02:08 | `dellfix` | 1 min | 02:08:18 | power key short press 16 s after the desktop came up, `PM: suspend entry (deep)`, never came back. nothing else running | `PM: suspend entry (deep)` |

one more oddity from the same period. on 2026-09-08 at 23:37 the first boot of
the stock 7.1.13 kernel stopped one second into userspace, at the journal
flush to disk, and the machine was booted again three minutes later. whether
that was a hang or a reset by hand is not recorded.

for comparison, the boots that did not hang: the stock 7.1.13 kernel ran 1 h
14 min with no suspend, and `dellfix` ran 2 h 30 min through two suspend
cycles on 2026-09-09 afternoon, both shut down cleanly.

## what the logs do and don't say

- no oops, no panic, no lockup report, no gpu fault, no thermal trip in any of
  the four. `/sys/fs/pstore` is empty, this platform has no ramoops region.
  the sbsa watchdog is present (`sbsa-gwdt 1c840000.watchdog`, 10 s timeout)
  but nothing arms it at runtime.
- every resume logs the same noise, and it also appears on the resumes that
  went fine: `IRQ120: set affinity failed(-22)` (irqbalance touching per cpu
  interrupts), `ath12k_wifi7_pci: qmi dma allocation failed (7274496 B type 1),
  will try later with small size`, `hwmon hwmon65: PM: parent phy0 should not
  be sleeping`. none of it is the hang.
- one real kernel warning, on the 20:27:21 resume in the boot of hang 3:

```
i2c i2c-4: Transfer while suspended
WARNING: drivers/i2c/i2c-core.h:56 at __i2c_transfer+0x6b4/0x6c8, CPU#0: kworker/0:0/9
Workqueue: events pmic_glink_altmode_worker [pmic_glink_altmode]
Call trace:
 __i2c_transfer+0x6b4/0x6c8 (P)
 regmap_i2c_read+0x64/0xc0
 ps883x_sw_set+0x94/0xf8 [ps883x]
 typec_switch_set+0x74/0xe0 [typec]
 pmic_glink_altmode_worker+0x48/0x3c8 [pmic_glink_altmode]
ps883x_retimer 4-0008: failed to set orientation: -108
pmic_glink_altmode.pmic_glink_altmode pmic_glink.altmode.0: failed to setup retimer to USB: -108
```

  the adsp's altmode notification arrives while the secondary cpus are still
  being brought back and before the i2c controller has resumed, so the type-c
  retimer write fails. once in seven resumes. it is a resume ordering bug on
  the pmic_glink path, it did not hang the machine (that boot ran another
  three and a half hours), but it is the only kernel warning on record and it
  sits on the suspend path.
- the `Forward time jump detected!` nine minutes after the resume in hang 2 is
  chrony noticing the system clock jump forward with no suspend to explain it.
  from userspace that is what a stall of several seconds looks like. so hang 2
  was probably preceded by a shorter freeze a few minutes earlier.

## the pattern

three of the four hangs on the patched kernel involve deep suspend. hang 4
died at suspend entry with nothing else going on. hang 2 came twelve minutes
after a resume, with a stall in between. hang 3 came fifteen minutes after the
last of four resumes, under gpu load. hang 1 predates every patch and had no
suspend, but also no cpufreq, so the machine was in a state it is never in now.

what changed between the stock kernel and `dellfix`, all of it new to the
suspend path: cpufreq now drives three clusters through scmi (schedutil,
idling at 710 mhz), the pwm backlight with `leds-qcom-lpg`, camss, camcc and
both cci controllers with the sensor node and `vreg_cam_1p8` always on, and
videocc with the iris codec. any of those is a device that now has suspend and
resume callbacks it did not have before, and none of them has been validated
across suspend.

## suspects, in order

1. **deep suspend and resume with the new devices in the tree.** the camera
   nodes (patches 0005 and 0006) are the least validated thing on the machine,
   the cci driver uses runtime pm and the sensor holds regulators. then the
   pmic_glink altmode race above, scmi cpufreq state across psci system
   suspend, and the lpg backlight on resume.
2. **the gpu under sustained load.** hangs 1 and 3 both had it, 2 and 4 did
   not.
3. not waydroid or binder. hang 2 predates its installation.

## what to do next

1. turn crash capture on now, it has not been on for any of the four:

```
sudo scripts/crash-capture.sh --pm-debug --panic
```

   the 1 s sync puts the freeze in the log. `--pm-debug` turns on
   `pm_debug_messages`, so a hang like 4 names the last device to suspend.
   `--panic` turns a soft or hard lockup into a logged panic and a reboot,
   which only helps if the cpus are still taking interrupts.
2. the cheapest discriminator for the suspend theory, for a day:

```
echo s2idle | sudo tee /sys/power/mem_sleep
```

   if the hangs stop, the deep path (psci system suspend, the cpus being
   killed and the socs power collapse) is where to look. it does not persist
   across a reboot. `mem_sleep_default=s2idle` on the kernel command line does.
3. the second discriminator is the camera. all three hangs on the patched
   kernel were with the camera patches in. those are opt in now
   (`build-kernel.sh --camera`), so the default `.dellfix` build is the
   kernel without them. run it for a day with deep suspend.

4. netconsole to another machine over the usb ethernet dongle,
   `scripts/crash-capture.sh --netconsole HOST`, is the only thing that gets a
   message out during a hang. wifi is no use, it is down through suspend.
5. arm the watchdog. `RuntimeWatchdogSec=30` in `/etc/systemd/system.conf`
   makes systemd pet `sbsa-gwdt`, so a hang where the cpus are dead reboots
   itself within 30 s. not evidence, but it separates "cpus dead" (it fires)
   from "cpus alive, display and input dead" (it does not), and it saves
   holding the power button.
6. the pmic_glink altmode warning is worth a report on its own to
   `linux-arm-msm` once there is a second occurrence, with the trace above.
