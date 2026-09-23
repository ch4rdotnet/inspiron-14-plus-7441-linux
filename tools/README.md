# tools

diagnostics, grouped by the subsystem they were written for. most answered one
question during bring-up and are kept because they show how something was
established, not just what the answer was. they source `scripts/lib.sh` and
need nothing else from the project. `--help` prints the header.

| folder | what is in it | doc |
|---|---|---|
| [cpufreq/](cpufreq/) | `verify-turbo.sh` kprobes `dev_pm_opp_add_dynamic` and reads the turbo flag out of the struct, the scmi diagnosis before committing to a kernel build. `try-cpufreq.sh` loads `scmi-cpufreq` by hand on a stock kernel, `--trace` is what found `cpufreq_frequency_table_cpuinfo` returning -22, `--persist` is the no-rebuild way to get cpufreq. | [docs/cpufreq.md](../docs/cpufreq.md) |
| [backlight/](backlight/) | `find-bl-pwm.sh` reads what uefi left configured (`/sys/kernel/debug/gpio` shows the hardware function for pmic gpios, pinctrl's own files don't). `edp-backlight.sh` decodes the panel's dpcd registers, which established it can't do aux brightness. `bl-sweep.sh` and `watch-brightness.sh` are for the unresolved flash. | [docs/backlight.md](../docs/backlight.md) |
| [touchscreen/](touchscreen/) | `probe-touchscreen.sh` reads the hid-over-i2c descriptor from each address that answers. found the touchscreen at 0x09. | [docs/touchscreen.md](../docs/touchscreen.md) |
| [fan/](fan/) | `probe-ec.sh` talks to the ec at i2c-3 0x3b, read only. `hunt-ec.sh` is everything needing root in the fan controller hunt, `--probe-i2c` scans the buses, which is what found the ec and the touchscreen. `qmi-tmd.py` is a qmi client for the thermal mitigation service, a template for any qualcomm firmware service. | [docs/fan-control.md](../docs/fan-control.md) |
| [acpi/](acpi/) | `acpi-dump.py` dumps the acpi tables uefi left in memory, through the `physmem/` module next to it. the technique that found the cci register bases. | [docs/acpi-tables.md](../docs/acpi-tables.md) |
| [camera/](camera/) | `probe-cci.sh` health check and bus scan, `capture-camera.sh` configures the camss pipeline and tries to grab frames, `raw10-to-png.py` makes a frame viewable. the out-of-tree modules (`ccidiag`, `camssdiag`, `ov02diag`, `aonmclk`, `mmiopeek`) and `prepare.sh` that builds the patch based ones, see [camera/README.md](camera/README.md). | [docs/camera.md](../docs/camera.md) |

the scripts that measure a working machine (`powerlog.sh`, `cpumon.sh`,
`find-unbound.sh`, `test-hwdec.sh`) are in [scripts/](../scripts/).

## the out-of-tree modules

`acpi/physmem` and the five under `camera/` build against the running kernel,
so `/lib/modules/$(uname -r)/build` has to exist, which means the matching
`kernel-devel`. for a kernel built by this project that rpm is in
`build/kernel/rpmbuild/RPMS/aarch64/`:

    sudo dnf install -y --disablerepo='*' build/kernel/rpmbuild/RPMS/aarch64/kernel-devel-<version>.rpm
    make -C tools/acpi/physmem

secure boot has to be off and lockdown off, or the modules need signing with
the key the kernel was built with. `KDIR=` points a build at a kernel tree
somewhere else.
