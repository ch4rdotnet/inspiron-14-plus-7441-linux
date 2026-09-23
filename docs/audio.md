# muffled audio, the tweeters were only getting the stereo difference signal

## symptom

sound is muffled overall, and the tweeters are barely audible.

## cause

this laptop has four speakers, a woofer and a tweeter per side, driven by four
WSA884x amps. the board describes them explicitly:

```dts
left_woofer:   speaker@0,0 { sound-name-prefix = "WooferLeft";   };
left_tweeter:  speaker@0,1 { sound-name-prefix = "TweeterLeft";  };
right_woofer:  speaker@0,0 { sound-name-prefix = "WooferRight";  };
right_tweeter: speaker@0,1 { sound-name-prefix = "TweeterRight"; };
```

alsa presents them as one 4 channel sink, and the channel positions are
`FL, FR, RL, RR`:

```
$ pw-dump | ... alsa_output.platform-sound.HiFi__Speaker__sink
audio.channels = 4
audio.position = [ FL, FR, RL, RR ]
```

so the tweeters occupy the rear channels. pipewire does not know that. its
default upmix method is `psd`, passive surround decoding, which synthesises the
rear channels from the difference between left and right, on the assumption
that rear speakers are there for ambience:

```
$ grep -r channelmix /usr/share/pipewire/client.conf
#channelmix.upmix      = true
#channelmix.upmix-method = psd  # none, simple
```

centred content (vocals, most music, speech) has almost no l-r difference, so
almost nothing reaches the tweeters. the result is all woofer and no treble.

it is not the amps. all four are configured identically and at full gain:

```
WooferLeft PA     Mono: 6 [100%] [0.00dB]      WooferLeft WSA MODE   Item0: 'Speaker'
TweeterLeft PA    Mono: 6 [100%] [0.00dB]      TweeterLeft WSA MODE  Item0: 'Speaker'
WooferRight PA    Mono: 6 [100%] [0.00dB]      ... COMP on, BOOST on for all four
TweeterRight PA   Mono: 6 [100%] [0.00dB]
```

## the upmix fix

`config/pipewire/51-tweeter-upmix.conf`:

```
stream.properties = {
    channelmix.upmix        = true
    channelmix.upmix-method = simple
}
```

`simple` copies front to rear rather than decorrelating it, so the tweeters get
the same signal as the woofers. it is installed twice, to
`/etc/pipewire/client.conf.d/` for native and alsa clients and to
`/etc/pipewire/pipewire-pulse.conf.d/` for pulseaudio clients. firefox is one of
the latter, and the pulse layer has its own `stream.properties`, so the
client.conf drop-in does not reach it. `scripts/install-audio-config.sh` installs
both, then `systemctl --user restart pipewire pipewire-pulse wireplumber`.

anything that was already playing keeps its old settings, the property is read
when a stream is created, so restart the player or browser. verify on a new
stream:

```
$ pw-dump | grep -A2 upmix
stream: PipeWire ALSA [speaker-test] | upmix = True | method = simple
```

the WSA884x amps run their own compressor and boost protection (COMP, PBR, CPS
all enabled), so they limit themselves rather than being damaged by the extra
low frequency content.

## the crossover

`config/pipewire/52-speaker-crossover.conf` (installed to
`/etc/pipewire/pipewire.conf.d/`) presents a normal stereo sink and splits it
with a linkwitz-riley 4th order crossover at 4 khz, lows to the woofers, highs
to the tweeters. lr4 is two cascaded butterworth biquads (q = 0.707) per branch,
which sum flat through the crossover region. two `copy` nodes fan each input
channel into both the low and high branch.

```
stereo in ->  dupL -> lpL1 -> lpL2 -> FL   (WooferLeft)
                   -> hpL1 -> hpL2 -> RL   (TweeterLeft)
              dupR -> lpR1 -> lpR2 -> FR   (WooferRight)
                   -> hpR1 -> hpR2 -> RR   (TweeterRight)
```

`stream.dont-remix = true` on the playback side stops pipewire re-mixing the
four channels it has deliberately built.

priority matters here. the filter sink has to outrank the raw speaker sink or
wireplumber picks the hardware directly and the crossover is bypassed, but it
must stay below headphones, or plugging them in leaves audio on the speakers:

| sink | priority | |
|---|---|---|
| `alsa_output.platform-sound.HiFi__Headphones__sink` | 1000 | wins when plugged in |
| `effect_input.speaker-crossover` | 900 | default |
| `alsa_output.platform-sound.HiFi__Speaker__sink` | 728 | |

verified end to end, firefox to crossover to all four hardware channels, hw sink
RUNNING:

```
effect_output.speaker-crossover:output_FL -> ...Speaker__sink:playback_FL
effect_output.speaker-crossover:output_FR -> ...Speaker__sink:playback_FR
effect_output.speaker-crossover:output_RL -> ...Speaker__sink:playback_RL
effect_output.speaker-crossover:output_RR -> ...Speaker__sink:playback_RR
```

the two upmix drop-ins are left in place as a fallback for anything that talks
to the hardware sink directly, bypassing the filter.

4 khz is a judgement call, not a measurement. it is a normal crossover point for
laptop tweeters of this size, but the vendor's real value is in the acdb, see
[audio-vendor-tuning.md](audio-vendor-tuning.md). if it sounds wrong, that
number is the one to change. edit `Freq` on all eight biquads (they must all
match) and restart pipewire.

to remove: delete the file from `/etc/pipewire/pipewire.conf.d/` and
`systemctl --user restart pipewire pipewire-pulse wireplumber`.

## ucm

there is no ucm profile for this machine. `/usr/share/alsa/ucm2/conf.d/x1e80100/`
maps TUXEDO, DEVKIT, CRD and EVK only, so it falls back to the generic
`x1e80100.conf`. the speaker section of the generic config is byte identical to
the latitude 7455's, so that is not a factor here, but a machine specific
profile would be the place to put a crossover properly.

## the /dev/snd acl race

seen once. the card registered, `/proc/asound/cards` showed it, but pipewire had
no local sinks. the cause was not audio at all:

```
$ getfacl /dev/snd/controlC0
user::rw-
user:gdm-greeter:rw-      <- not the logged in user
group::rw-
```

the card only appears once the adsp has booted, which landed in the middle of
gdm starting. logind's `uaccess` rule grants the acl to whoever is the active
session at that instant (`gdm-greeter`) and does not re-apply it when the real
user logs in a second later. `scripts/fix-audio-acl.sh` grants it for the boot,
and `--permanent` adds the user to the `audio` group so it can't recur. it has
not recurred, so the permanent fix has not been applied.
