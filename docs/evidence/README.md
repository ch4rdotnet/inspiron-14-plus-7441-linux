# raw dumps kept as evidence

unprocessed output from the bring-up investigations. the conclusions drawn from
these live in the docs, these are here so the reasoning can be re-checked.

| file | what it is | backs |
|---|---|---|
| `initial-hardware-probe.txt` | the first full hardware probe, before anything was fixed | [../hardware.md](../hardware.md), [../status.md](../status.md) |
| `cpufreq-dynamic-debug.txt`, `cpufreq-dynamic-debug-2.txt` | dynamic_debug output across cpufreq, arm_scmi and opp while chasing the missing policies | [../cpufreq.md](../cpufreq.md) |
| `backlight-pinctrl-dump.txt`, `backlight-pinctrl-dump-2.txt` | pinctrl and gpio state while finding the backlight pwm pin (PMK8550 gpio5 func3) | [../backlight.md](../backlight.md) |

the `collect-state.sh` snapshots taken before and after each fix are not
published, they contain mac addresses and the battery serial. regenerate one on
the machine with `scripts/collect-state.sh`.
