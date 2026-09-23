#!/usr/bin/env bash
# talk to the embedded controller, read only
#
#   sudo probe-ec.sh
#
# there is an ec, at 0x3b on the bus behind b94000.i2c (acpi \_SB.I2C6, dt
# i2c5). it answers 64 byte block reads, the dsdt documents a 0xfb vendor
# command with 0x22 "read fan", but that returns the same telemetry buffer as
# the plain read. see docs/fan-control.md. this bus is shared with two usb
# redrivers, don't add blind writes.

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_cmd i2ctransfer i2c-tools

# find the bus by register address, i2c numbering isn't stable across kernels
bus=""
for d in /sys/bus/i2c/devices/i2c-*; do
    readlink -f "$d" | grep -q 'b94000\.i2c' && { bus=${d##*i2c-}; break; }
done
[[ -n $bus ]] || die "b94000.i2c has no i2c adapter, is &i2c5 enabled?"
EC=0x3b
echo "ec on i2c-$bus at $EC"

echo
echo "does it answer"
# capture first, piping i2cdetect into grep -q under pipefail makes it die of sigpipe
scan=$(sudo i2cdetect -y -r "$bus" 2>/dev/null)
grep -q ' 3b' <<<"$scan" && echo "  yes, 0x3b acks" || die "no ack at 0x3b"

echo
echo "64 byte block read at command 0x00"
raw=$(sudo i2ctransfer -y "$bus" "w1@$EC" 0x00 r64 2>&1) || die "read failed: $raw"
tr ' ' '\n' <<<"$raw" | sed 's/0x//' | paste -sd' ' - | fold -w 72 | sed 's/^/  /'

echo
echo "decoded as (temp, sensor id, flags) triplets from offset 4"
# speculative, the values sit in a chassis temperature range and the ids
# increment, but they have not been seen to move
tr ' ' '\n' <<<"$raw" | sed -n '5,22p' | paste - - - |
    awk '{printf "  temp=%3d c   id=%2d   flags=%s\n", strtonum($1), strtonum($2), $3}'

echo
printf 'hottest tsens for comparison: %s c\n' \
    "$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1 | awk '{print $1/1000}')"

echo
echo "documented fan read (dsdt RFAN, write fb 22 <fan>, read back)"
for f in 0 1; do
    printf '  fan%s: %s\n' "$f" "$(sudo i2ctransfer -y "$bus" "w3@$EC" 0xfb 0x22 "$f" r6 2>&1)"
done
echo "  plain read for comparison: $(sudo i2ctransfer -y "$bus" "w1@$EC" 0x00 r6 2>&1)"
