# vendor audio tuning, what is in the driver pack and what can be done with it

the question was whether the dell driver pack contains speaker tuning that could
be reused. it does, for this exact board, but only part of it is usable.

## what is in there

```
Latitude-7455/Win11/arm64/audio/RR89D_A00-00/qcacsp_crd8380/
    acdb_cal_thena2.acdb        494 KB   <- this board ("thena" is the codename in x1-dell-thena.dtsi)
    acdb_cal_FG.acdb            553 KB
    acdb_cal_Sable.acdb         553 KB
    acdb_cal_tributo.acdb       493 KB
    workspaceFile_thena2.qwsp   624 KB   <- encrypted
```

the two thena2 files are vendor data and are not in this repo. they extract from
the same driver pack the firmware comes from, see [firmware.md](firmware.md).

## the acdb parses

`.acdb` is qualcomm's audio calibration database, a 12 byte header then fourcc
chunks. it walks cleanly to exactly eof, so the structure is sound:

```
0x00000c  HEAD  42        0x0135ea  SCLU  2548       0x01f3c6  SGIT  11436
0x00003e  GKVT  192       0x014532  MTKT  1768       0x02207a  POOL  351808   <- payloads
0x000106  GKVL  2548      0x014c22  MTLU  21480      0x077ec2  GCLU  184
0x000b02  CSLU  2756      0x01a012  MTDE  3192       ...
0x00160e  CDLU  40328     0x01b7fe  TMLU  7828       0x0787b6  MODM  284
                                                     (30 chunks, ends 0x788da = file size)
```

the 344 kb `POOL` holds the actual module parameter payloads. the `*LU`, `*DE`
and `*DO` chunks are the lookup, definition and offset tables that index into
it.

the modules it configures can be named straight from the kernel's own
audioreach headers:

```
0x07001002 x52    MODULE_ID_GAIN                 0x07001023 x33   MODULE_ID_CODEC_DMA_SINK
0x07001010 x99    MODULE_ID_SAL                  0x07001024 x65   MODULE_ID_CODEC_DMA_SOURCE
0x07001015 x226   MODULE_ID_MFC                  0x070010e2 x17   MODULE_ID_SPEAKER_PROTECTION
0x0700101a x624   MODULE_ID_DATA_LOGGING         0x070010e3 x17   MODULE_ID_SPEAKER_PROTECTION_VI
```

`MODULE_ID_SPEAKER_PROTECTION` and `MODULE_ID_SPEAKER_PROTECTION_VI` are present.
that is the excursion and thermal model for these speakers, the vendor's actual
per driver tuning. the highest count unnamed ids (`0x0700101b` x387,
`0x07001097` x329, `0x07001019` x225) are the likely eq and drc blocks. those
ids are not in the upstream headers.

## the catch, in order of severity

1. **the readable one is encrypted.** `.qwsp` is a qact workspace, the tuning
   project, with labelled eq curves and crossover points. it is high entropy
   with no recoverable strings. that is the file that would have made this
   easy, and it is not available.
2. **getting values out of the acdb is real reverse engineering.** the
   container parses, but each parameter payload needs the lookup tables walked
   and the per module parameter layout known. nothing upstream documents those
   layouts for the eq modules.
3. **linux cannot load it even if extracted.** upstream `q6apm` and audioreach
   do not consume acdb, and more to the point this machine's audio path does
   not run the vendor dsp topology at all. playback goes to the WSA amps with no
   dsp processing in between. there is nothing to load it into.

## so what is it actually good for

only as a source of numbers to re-implement by hand. the realistic use is to
extract the crossover frequency and eq curves and rebuild them as a pipewire
`filter-chain` in front of the speaker sink, which is what
[audio.md](audio.md) already does with a guessed 4 khz, just with vendor
numbers instead.
