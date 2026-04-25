Metaanalysis on FreeBSD Audio Stack and My Findings While Tuning My Daily Driver

## FreeBSD Audio Stack: Complete Configuration Guide

FreeBSD's audio model is fundamentally **OSS-based** (Open Sound System), not ALSA — the kernel exposes `/dev/dspN`, `/dev/mixerN`, and `/dev/sndstat`. ALSA, PulseAudio, PipeWire, and JACK all sit on top of this, either natively or via adaptation layers. Here's a full breakdown, layer by layer.

**Interactive toolkit** — launch the main TUI to access all scripts:

```sh
./audio-toolkit.sh
```

***

## Layer 0: Kernel & Drivers

This is the foundation. Everything else depends on it.

### `/boot/loader.conf` — Driver Loading

This file is parsed at boot **before the kernel runs**, making it the right place for driver modules. [docs-archive.freebsd](https://docs-archive.freebsd.org/doc/12.1-RELEASE/usr/local/share/doc/freebsd/en/books/handbook/sound-setup.html)

```
# For Intel HDA (most modern motherboards/laptops)
snd_hda_load="YES"

# For USB audio (headsets, USB DACs, interfaces)
snd_uaudio_load="YES"

# Lazy option: loads ALL common sound drivers
snd_driver_load="YES"

# Required for virtual_oss (userspace character devices)
cuse_load="YES"
```

Check available snd modules with `man -k snd`. You can see which loaded drivers were detedetected with `dmesg | grep pcm`  [huge-man-linux](https://www.huge-man-linux.net/man4extras/man4freebsd/sound.html).

### `/boot/device.hints` — HDA Pin Configuration

For HDA chipsets where auto-switching between speakers and headphones fails: [freebsdfoundation](https://freebsdfoundation.org/freebsd-project/resourcesold/audio-on-freebsd/)

```
# Values come from: dmesg | grep pcm  (nid numbers)
hint.hdac.0.cad0.nid22.config="as=1 seq=15 device=Headphones"
hint.hdac.0.cad0.nid26.config="as=2 seq=0 device=speakers"
```

For this purpose I used the following command:

```sh
./configure-hda-hints.sh
```

Your `nidXX` numbers will differ — always read them from `dmesg | grep pcm` first  [freebsdfoundation](https://freebsdfoundation.org/freebsd-project/resourcesold/audio-on-freebsd/).

### `/etc/sysctl.conf` — Runtime Kernel Tuning

These take effect at boot via `sysctl(8)`. Most audio-related ones live under `hw.snd.*`: [micski](https://www.micski.dk/2024/01/20/setting-default-audio-device-in-freebsd/)

```
# Set default output device (unit number from /dev/sndstat)
hw.snd.default_unit=4

# Number of virtual channels per direction (increase for heavy multitasking)
hw.snd.maxautovchans=16

# Audio latency profile: 0=lowest latency, 10=highest buffer
hw.snd.latency=5
hw.snd.latency_profile=1

# Extra verbosity in /dev/sndstat (useful for debugging)
# set to 0 in production
# hw.snd.verbose=2
```

For this purpose script for sysctl tuning over pcm devices with 4 available profiles:

```sh
./tune-pcm-sysctls.sh <profile> (low-latency, desktop, server, bitperfect)
```

> **Note:** `hw.snd.default_unit` set in `/etc/sysctl.conf` runs after device detection, which is why it works where `loader.conf` doesn't for this variable. [forums.freebsd](https://forums.freebsd.org/threads/cant-set-default-snd-unit-from-loader-conf.75184/)

### Key diagnostic commands

```sh
cat /dev/sndstat          # list all pcm devices
dmesg | grep pcm          # driver enumeration order
sysctl -a | grep hw.snd   # all current audio sysctl values
mixer                     # show volumes for default device
mixer -f /dev/mixer4      # show volumes for specific device
```

***

## Layer 1: virtual_oss — The Native Sound Server

`virtual_oss` is the **recommended sound multiplexer for FreeBSD**. It takes a single real `/dev/dspN` device and splits it into multiple virtual OSS devices that many apps can use simultaneously. It's written by hselasky (the same person who wrote `cuse` and `snd_uaudio`) and is extremely stable. [man.freebsd](https://man.freebsd.org/cgi/man.cgi?query=virtual_oss&sektion=8&manpath=FreeBSD+11.1-RELEASE+and+Ports)

### Installation & Service Enable

```sh
pkg install virtual_oss
sysrc virtual_oss_enable="YES"
service virtual_oss start
```

Script for checking virtual_oss sanity:

```sh
./check-virtual-oss.sh
```

```
./setup-virtual-oss.sh — interactive, asks before each change
./setup-virtual-oss.sh --auto — apply everything automatically
./setup-virtual-oss.sh --dry-run — preview only
```

### `/etc/rc.conf` — virtual_oss Configuration

This is the primary configuration mechanism for `virtual_oss`: [meka](https://meka.rs/blog/2021/10/12/freebsd-audio/)

```sh
virtual_oss_enable="YES"

# Multiple named configs are supported:
virtual_oss_configs="dsp dummy"

# Main hardware config — stereo, 48kHz, 32-bit
virtual_oss_dsp="-T /dev/sndstat -S -i 8 -C 18 -c 18 -r 48000 -b 32 -s 768 \
  -f /dev/dsp0 \
  -c 2 -w dsp.wav -d dsp \
  -t dsp.ctl"

# Dummy config for jailed testing (uses /dev/null as backend)
virtual_oss_dummy="-T /dev/sndstat -S -i 8 -C 2 -c 2 -r 48000 -b 32 -s 768 \
  -f /dev/null \
  -c 2 -w vdsp.wav -d vdsp \
  -t vdsp.ctl"
```

### Key flags decoded

| Flag | Meaning |
|---|---|
| `-f /dev/dspX` | Physical backend device |
| `-r 48000` | Sample rate |
| `-b 32` | Bit depth (8/16/24/32) |
| `-s 768` | Buffer size in samples (lower = less latency) |
| `-c N` | Channel count |
| `-C N` | Total virtual channel capacity |
| `-d name` | Creates `/dev/name` virtual device |
| `-t name.ctl` | Creates control socket for runtime changes |
| `-w name.wav` | Creates WAV-format recording device |
| `-S` | Enable automatic sample rate resampling |
| `-i N` | Real-time priority (uses `rtprio`) |
| `-M i,src,dst,...` | Channel routing/mixing matrix entries |

Managable with the following script:

```sh
./configure-virtual-oss.sh
```

### Runtime switching

```sh
# Switch active hardware output on the fly (no restart needed)
virtual_oss_cmd /dev/dsp.ctl -f /dev/dsp0   # switch to onboard
virtual_oss_cmd /dev/dsp.ctl -f /dev/dsp6   # switch to USB headset
virtual_oss_cmd /dev/dsp.ctl -f /dev/null   # mute (useful before suspend)
```

Or use the interactive TUI which auto-detects control sockets and available devices:

```sh
./switch-audio-output.sh
```


### `/etc/rc.suspend` and `/etc/rc.resume` — Suspend safety [badland](https://badland.io/freebsd-usb-headphones.md)

```sh
# /etc/rc.suspend  (before the acpiconf -k line!)
virtual_oss_cmd /dev/dsp.ctl -f /dev/null
sleep 1

# /etc/rc.resume
virtual_oss_cmd /dev/dsp.ctl -f /dev/dsp7
```

Check and fix these automatically:

```sh
./configure-suspend-audio.sh
```

### `/etc/devfs.rules` — Hide raw devices from apps [badland](https://badland.io/freebsd-usb-headphones.md)

Prevents apps like PulseAudio or desktop volume monitors from opening raw hardware devices and blocking `virtual_oss`:

```
[audio=6]
add include $devfsrules_hide_all
add include $devfsrules_unhide_basic
add include $devfsrules_unhide_login
add path 'dsp*' unhide mode 0666
add path 'vdsp*' unhide mode 0666
add path '*midi*' unhide mode 0666
add path 'mixer*' unhide mode 0666
add path 'sndstat' unhide mode 0666
```

For hiding specific raw USB devices from misbehaving apps (e.g., if your USB headset is `dsp7`):

```
add path 'dsp[789]' hide
add path 'mixer[789]' hide
```

Activate with `sysrc devfs_system_ruleset="audio"` in `/etc/rc.conf`.

Check and fix all of the above automatically:

```sh
./configure-devfs-audio.sh             # interactive (prompts before each fix)
./configure-devfs-audio.sh --auto      # apply all fixes without prompting
./configure-devfs-audio.sh --dry-run   # check only, no changes
```

### `/usr/local/etc/devd/` — USB Hotplug [badland](https://badland.io/freebsd-usb-headphones.md)

Auto-switch `virtual_oss` on USB attach/detach using `devd`:

```sh
# /usr/local/etc/devd/headset.conf
notify 100 {
    match "system"    "USB";
    match "subsystem" "INTERFACE";
    match "type"      "ATTACH";
    match "vendor"    "0x1038";   # your device's idVendor from usbconfig
    action "/usr/local/sbin/virtual_oss_cmd /dev/dsp.ctl -f /dev/dsp7";
};

notify 100 {
    match "system"    "USB";
    match "subsystem" "INTERFACE";
    match "type"      "DETACH";
    match "vendor"    "0x1038";
    action "/usr/local/sbin/virtual_oss_cmd /dev/dsp.ctl -f /dev/null";
};
```

Get your vendor ID with `usbconfig -d ugenX.Y dump_device_desc`.

Detect USB audio devices and generate/fix devd rules automatically:

```sh
./configure-devd-audio.sh             # interactive
./configure-devd-audio.sh --auto      # apply all fixes without prompting
./configure-devd-audio.sh --dry-run   # check only, no changes
```

***

## Layer 2: PulseAudio

PulseAudio is fully supported on FreeBSD and works on top of OSS. Use it when you need apps that explicitly require PulseAudio (e.g., some Flatpaks, Discord builds, older Chromium). [man.freebsd](https://man.freebsd.org/cgi/man.cgi?query=pulseaudio&manpath=FreeBSD+12.1-RELEASE+and+Ports)

### File locations

| File | Purpose |
|---|---|
| `~/.config/pulse/daemon.conf` | Per-user daemon settings (overrides system) |
| `/usr/local/etc/pulse/daemon.conf` | System-wide daemon settings |
| `~/.config/pulse/client.conf` | Per-user client lib settings |
| `/usr/local/etc/pulse/client.conf` | System-wide client settings |
| `~/.config/pulse/default.pa` | Per-user module load script |
| `/usr/local/etc/pulse/default.pa` | System-wide module script |
| `~/.config/pulse/client.conf.d/*.conf` | Drop-in client overrides |

### `/usr/local/etc/pulse/daemon.conf` key settings

```
# Use OSS backend on FreeBSD (not ALSA)
default-sample-rate = 48000
default-sample-format = s16le
realtime-scheduling = yes
realtime-priority = 5
resample-method = soxr-vhq

# Prevent autospawn if using a session manager
; autospawn = no
```

### `/usr/local/etc/pulse/default.pa` — module loading

```
# OSS output — point to your virtual_oss device
load-module module-oss device=/dev/dsp sink_name=oss_out source_name=oss_in
set-default-sink oss_out
set-default-source oss_in

# Or use native protocol for remote audio
load-module module-native-protocol-unix
```

### Start PulseAudio

```sh
# As user (most common)
pulseaudio --start

# Check it's running
pulseaudio --check && echo "running"

# Force re-read config
pulseaudio --kill && pulseaudio --start

# Inspect live state
pacmd list-sinks
pacmd set-default-sink 0
```

Check, fix, and tune all of the above:

```sh
./configure-pulseaudio.sh             # CLI: check and prompt to fix
./configure-pulseaudio.sh --auto      # apply all fixes without prompting
./configure-pulseaudio.sh --dry-run   # check only, no changes
./configure-pulseaudio.sh --tui       # interactive settings editor
```

***

## Layer 2 (alternative): ALSA on FreeBSD

FreeBSD does **not** have a native ALSA kernel layer  — ALSA here is provided by `audio/alsa-plugins` + `audio/alsa-lib` which are **wrappers that map ALSA calls to OSS**. Install: [bugs.freebsd](https://bugs.freebsd.org/272004)

```sh
pkg install alsa-lib alsa-plugins alsa-utils
```

### `~/.asoundrc` and `/usr/local/etc/asound.conf`

The per-user `~/.asoundrc` takes precedence over the system `/usr/local/etc/asound.conf`. These files are in SPA-like key-value format. Since FreeBSD's ALSA is OSS-backed, the most useful config is just pointing to the right OSS device: [github](https://github.com/markc/alsa/blob/master/lib/md/Asoundrc.md)

```
# ~/.asoundrc
pcm.!default {
    type oss
    device /dev/dsp     # virtual_oss device
}

ctl.!default {
    type oss
    device /dev/mixer
}
```

`/usr/local/etc/asound.conf` is the system equivalent. Without these files, `alsa-lib` picks a default that may or may not match your `virtual_oss` device. [alsa-project](https://www.alsa-project.org/wiki/Asoundrc)

> In practice, on FreeBSD you rarely need complex `.asoundrc` configs. Most apps using ALSA on FreeBSD should just work if you have `virtual_oss` running and `alsa-plugins` installed.

Check, fix, and tune ALSA configuration:

```sh
./configure-alsa.sh             # CLI: check and prompt to fix
./configure-alsa.sh --auto      # apply all fixes without prompting
./configure-alsa.sh --dry-run   # check only, no changes
./configure-alsa.sh --tui       # interactive settings editor
```

***

## Layer 2 (pro audio): JACK

JACK is the standard for low-latency pro audio and DAW work on FreeBSD. It operates directly on `/dev/dspN` — **point it at your real hardware device, not the virtual_oss device**. [forums.freebsd](https://forums.freebsd.org/threads/obs-studio-with-jack-audio-and-the-freebsd-realtime-kernel-module.92066/)

### `/etc/rc.conf` — JACK daemon settings [bugs.freebsd](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=269929)

```sh
jackd_enable="YES"
jackd_user="youruser"
jackd_rtprio="YES"
jackd_args="-R -d oss -r 48000 -p 1024 -n 3 -w 16 --capture /dev/dsp1 --playback /dev/dsp1"
```

### Real-time priority setup (critical for JACK)

```sh
# Add user to realtime group
pw groupmod realtime -m youruser

# Load mac_priority kernel module (enables POSIX real-time scheduling)
sysrc kld_list+="mac_priority"
kldload mac_priority
```

Without `mac_priority`, JACK will run but you'll get xruns under load. [forums.freebsd](https://forums.freebsd.org/threads/obs-studio-with-jack-audio-and-the-freebsd-realtime-kernel-module.92066/)

### Launch JACK manually

```sh
# OSS backend, 48kHz, buffer 1024 samples, 3 periods, 16-bit
jackd -R -d oss -r 48000 -p 1024 -n 3 --capture /dev/dsp1 --playback /dev/dsp1

# With qjackctl GUI
pkg install qjackctl
qjackctl &
```

In `qjackctl`, under Setup → Server Path, prefix the command with `pasuspender --` if PulseAudio is also running — this suspends PA while JACK is active. [linuxmusicians](https://linuxmusicians.com/viewtopic.php?t=13234)

### PulseAudio as a JACK client (optional bridge)

```sh
pacmd load-module module-jack-sink channels=2
pacmd load-module module-jack-source channels=2
pacmd set-default-sink jack_out
pacmd set-default-source jack_in
```

Check, fix, and tune JACK configuration:

```sh
./configure-jack.sh             # CLI: check and prompt to fix
./configure-jack.sh --auto      # apply all fixes without prompting
./configure-jack.sh --dry-run   # check only, no changes
./configure-jack.sh --tui       # interactive settings editor
```

***

## Layer 3: PipeWire

PipeWire on FreeBSD is **functional but still rough** compared to Linux. Audio via PW currently requires the OSS backend (no native ALSA kernel to target), and the ALSA plugin must be properly configured. It's most useful if you need screen capture portals (e.g., for Wayland/Niri/sway), as those depend on PipeWire. [vermaden.wordpress](https://vermaden.wordpress.com/2024/01/13/freebsd-desktop-part-29-configuration-audio-improvements/)

### Installation

```sh
pkg install pipewire pipewire-pulse wireplumber rtkit
```

### Config file locations (FreeBSD paths) [man.freebsd](https://man.freebsd.org/cgi/man.cgi?query=pipewire.conf&sektion=5&manpath=FreeBSD+13.2-RELEASE+and+Ports)

| File | Purpose |
|---|---|
| `/usr/local/share/pipewire/pipewire.conf` | Upstream default (do not edit) |
| `/usr/local/etc/pipewire/pipewire.conf` | System override |
| `~/.config/pipewire/pipewire.conf` | Per-user override |
| `/usr/local/etc/pipewire/pipewire.conf.d/*.conf` | System drop-ins |
| `~/.config/pipewire/pipewire.conf.d/*.conf` | Per-user drop-ins |
| `/usr/local/share/pipewire/wireplumber.conf` | WirePlumber default |
| `~/.config/wireplumber/` | WirePlumber per-user config dir |

**Use drop-ins, never edit the defaults directly**. Example: [manpages.debian](https://manpages.debian.org/testing/pipewire-bin/pipewire.conf.5.en.html)

```
# ~/.config/pipewire/pipewire.conf.d/latency.conf
context.properties = {
    default.clock.min-quantum = 128
    default.clock.max-quantum = 1024
    default.clock.quantum = 512
}
```

### Required environment variables [discussion.fedoraproject](https://discussion.fedoraproject.org/t/something-broke-my-pipewire-wireplumber/140003?page=3)

PipeWire **will not start** without these:

```sh
# In your shell profile (~/.profile, ~/.xinitrc, or session script)
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
```

If using `seatd` + `pam_xdg`, `XDG_RUNTIME_DIR` is set automatically on login. [bugs.freebsd](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=268726)

### Starting PipeWire (without systemd)

```sh
# Manual start (in .xinitrc or session startup)
daemon -f pipewire
daemon -f pipewire-pulse
daemon -f wireplumber
```

Or via the FreeBSD rc service if your build includes it: [forums.freebsd](https://forums.freebsd.org/threads/no-sound-in-wayland.97788/)

```sh
sysrc pipewire_enable="YES"
service pipewire start
```

### ALSA fix for PipeWire on FreeBSD [bugs.freebsd](https://bugs.freebsd.org/272004)

Install the OSS-default config drop-in:

```sh
pkg install alsa-plugins
# Then ensure this file is in place:
# /usr/local/etc/pipewire/pipewire.conf.d/alsa-default.conf
# (It maps ALSA calls to OSS since FreeBSD has no ALSA kernel layer)
```

Check, fix, and tune PipeWire (including systemd workarounds):

```sh
./configure-pipewire.sh             # CLI: check and prompt to fix
./configure-pipewire.sh --auto      # apply all fixes without prompting
./configure-pipewire.sh --dry-run   # check only, no changes
./configure-pipewire.sh --tui       # interactive settings editor
```

***

## Quick Reference: File Map

| Layer | File | What it controls |
|---|---|---|
| Kernel | `/boot/loader.conf` | Driver modules loaded at boot |
| Kernel | `/boot/device.hints` | HDA pin/headphone switching |
| Kernel | `/etc/sysctl.conf` | `hw.snd.*` runtime tuning, default unit |
| OSS/devfs | `/etc/devfs.rules` | Device visibility and permissions |
| OSS/devd | `/usr/local/etc/devd/*.conf` | USB hotplug actions |
| virtual_oss | `/etc/rc.conf` | `virtual_oss_*` parameters |
| virtual_oss | `/etc/rc.suspend` / `/etc/rc.resume` | Device release before suspend |
| PulseAudio | `/usr/local/etc/pulse/daemon.conf` | PA daemon tuning |
| PulseAudio | `/usr/local/etc/pulse/default.pa` | Module loading, sink/source config |
| PulseAudio | `~/.config/pulse/client.conf` | Per-user default sink/server |
| ALSA | `~/.asoundrc` | Per-user PCM/CTL routing to OSS |
| ALSA | `/usr/local/etc/asound.conf` | System-wide ALSA→OSS mapping |
| JACK | `/etc/rc.conf` (`jackd_*`) | jackd service config, RT priority |
| PipeWire | `~/.config/pipewire/pipewire.conf.d/` | Drop-in PW config |
| PipeWire | `~/.config/wireplumber/` | Session manager policy |

***

## Recommended Stack for Daily Use (at least for my case)

For a desktop FreeBSD system, the most stable and idiomatic setup is: [iyer](https://iyer.ru/2025/09/29/how-to-switch-audio-output-in-freebsd-on-the-fly/)

```
Kernel (snd_hda / snd_uaudio) → virtual_oss → apps via /dev/dsp
                                             → PulseAudio (if needed by apps)
                                             → JACK (via real /dev/dsp1)
```

PipeWire should be added only if you specifically need Wayland screencasting portals — for audio alone, `virtual_oss` + optionally PulseAudio gives you a more reliable and better-supported setup on FreeBSD today. [vermaden.wordpress](https://vermaden.wordpress.com/2024/01/13/freebsd-desktop-part-29-configuration-audio-improvements/)


TODO://

- [ ] Be 100% sure that there is no issue on pipewire behaviour (maybe existing rust packages could be used as a temporary replacement)
- [ ] Add a script to check for missing files and missing lines in files
- [ ] Add a script to check for any deadlock and broken pipe
- [ ] Add a script to be sure the sockets are properly orchestrated
