# boot time: 90 seconds waiting for a tpm, then 5 more for a usb stick

from 1:58 to 15 seconds, in two steps.

## the tpm wait

every boot stalled twice for 45 seconds, on `dev-tpm0.device` and
`dev-tpmrm0.device`.

```
$ systemd-analyze
Startup finished in 1.173s (kernel) + 46.503s (initrd) + 1min 11.113s (userspace) = 1min 58.790s
$ journalctl -b | grep -i 'timed out'
systemd[1]: Timed out waiting for device dev-tpm0.device - /dev/tpm0.
systemd[1]: Timed out waiting for device dev-tpmrm0.device - /dev/tpmrm0.
```

### cause

there is no tpm driver bound, so those device nodes never appear:

```
$ dmesg | grep -i tpm
ima: No TPM chip found, activating TPM-bypass!
$ ls /dev/tpm*
No such file or directory
```

the machine does have a tpm. the uefi publishes a `TPM2` acpi table, efi hands
over `TPMEventLog` and `TPMFinalLog`, and the device tree reserves
`tpm-control@81f10000`. but it is a firmware tpm living in trustzone, and
nothing upstream drives it on a dt boot (`tpm_crb` is acpi only here, and
`tpm_ftpm_tee` is for op-tee, not qualcomm's qsee).

systemd still expects it, because `sysinit.target` pulls in `tpm2.target`,
which wants both device units:

```
$ systemctl list-dependencies --reverse dev-tpm0.device
dev-tpm0.device
└─tpm2.target
  └─sysinit.target
$ systemctl show dev-tpm0.device -p JobRunningTimeoutUSec
JobRunningTimeoutUSec=45s
```

45 s each, once in the initrd and once in userspace. that is the whole 90
seconds.

### fix

nothing on this machine can use a tpm. the root disk is luks now, but it is
unlocked by passphrase and nothing is enrolled against the ftpm (there is still
no driver for it). so stop waiting for it. `scripts/disable-tpm-wait.sh` does
three things:

userspace:

```
sudo systemctl mask dev-tpm0.device dev-tpmrm0.device
```

initrd. masking in `/etc/systemd/system` does not reliably reach the
initramfs, and omitting the `tpm2-tss` dracut module does not remove
`tpm2.target` either, so mask on the kernel command line instead. fedora is
bls, so `grubby` rather than `/etc/default/grub`:

```
sudo grubby --update-kernel=ALL \
    --args="rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"
```

and `config/dracut/99-no-tpm.conf` drops `tpm2-tss` from the initramfs, which
is tidy but is not the part that saves the time.

to undo, `sudo scripts/disable-tpm-wait.sh --undo`, which unmasks the units,
removes the dracut conf and strips the arguments again. if a driver for the
qualcomm ftpm ever lands, undo all of it, the wait would then be legitimate.
the script also refuses to do anything if `/dev/tpm0` exists.

## what was left afterwards, and a gotcha

with the tpm wait gone, boot was 19.681 s (1.033 kernel + 12.089 initrd +
6.558 userspace). the initrd was then the biggest remaining piece, and almost
all of it was one unit:

```
dracut-initqueue.service   3.544s -> 12.780s   = 9.24s
```

but the root device was found at 7.838 s, nearly 5 seconds before initqueue
finished. so the root was not what it was waiting on. things that turned out
not to matter:

- `systemd-fsck-root`: 0.046 s.
- the 22 mb adsp firmware this project adds to the initramfs: 0.33 s (7.459 to
  7.785). loading and authenticating it is essentially free, which is worth
  knowing, it is not the price of having battery and audio.
- it was not a retry loop either, only ~15 log lines across those 4.8 seconds,
  mostly silence.

it was a usb stick left plugged in. dracut scans removable block devices
looking for the root, and a sandisk (`0781:55a9`) enumerating at 7.915 s held
`dracut-initqueue` open for another five seconds. unplugging it:

| | stick in | stick out |
|---|---|---|
| initrd | 12.089 s | 7.359 s |
| `dracut-initqueue` | 9.24 s | 3.44 s |
| root found to initqueue done | 4.94 s | 0.10 s |
| total | 19.681 s | 15.045 s |

initqueue now exits a tenth of a second after the root appears, which is what
it should do. so, if boot suddenly gets slower, check for a plugged in usb
drive before anything else.

the other suspect at the time was `ath12k` wifi probing on pcie `1c08000`
inside the initrd, which could be dropped with `rd.driver.blacklist=ath12k`.
that turned out to be unnecessary and was not done. touching the initramfs is
not worth it when it also carries the adsp firmware that battery and audio
depend on.

`systemd-analyze blame` still lists `sys-module-fuse.device` and
`sys-module-configfs.device` at the top. ignore them. for a `.device` unit
blame reports when the device appeared, not time spent, and nothing depends on
either (`WantedBy=` and `RequiredBy=` are both empty, and neither is in
`systemd-analyze critical-chain`).
