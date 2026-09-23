#!/usr/bin/env bash
# read the hid-over-i2c descriptor from the addresses that answer on the touchscreen bus
#
#   sudo probe-touchscreen.sh
#
# the dt said touchscreen@10 but the scan shows 0x09 and 0x28 answering and
# nothing at 0x10. writing the 2 byte descriptor register and reading 30 back
# is the defined way to talk to any hid-over-i2c device, a valid reply starts
# 1e 00 00 01 (length 30, bcdVersion 1.00). nothing is configured.

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root
need_cmd i2ctransfer i2c-tools

# the bus behind a80000.i2c, numbering isn't stable across kernels
bus=""
for d in /sys/bus/i2c/devices/i2c-*; do
    readlink -f "$d" | grep -q 'a80000\.i2c' && { bus=${d##*i2c-}; break; }
done
[[ -n $bus ]] || die "a80000.i2c has no adapter"

hid_probe() {  # addr [descr_addr]
    local addr=$1 da=${2:-1} out b
    printf '  addr %-5s ' "$addr"
    out=$(i2ctransfer -y "$bus" w2@"$addr" $(( da & 0xff )) $(( (da >> 8) & 0xff )) r30 2>&1)
    if [[ $out == *rror* ]]; then echo "no response"; return; fi
    echo; echo "    raw: $out"
    read -ra b <<<"$out"
    if [[ ${b[0]} == 0x1e && ${b[2]} == 0x00 && ${b[3]} == 0x01 ]]; then
        echo "    valid hid-over-i2c descriptor, vid ${b[21]#0x}${b[20]#0x} pid ${b[23]#0x}${b[22]#0x}"
    else
        echo "    responds, but not a hid descriptor"
    fi
}

echo "bus i2c-$bus (a80000.i2c)"
scan=$(i2cdetect -y -r "$bus" 2>/dev/null); echo "$scan" | sed 's/^/  /'
echo
for a in 0x09 0x10 0x28; do hid_probe "$a"; done
