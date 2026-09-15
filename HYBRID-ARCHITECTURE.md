# Hybrid Architecture: udev + systemd

The optimizer has no daemon. udev reports when a USB audio interface appears
or disappears, and three small systemd units apply or undo the optimizations
at the moments that matter: after login, after the JACK server has started,
and after a wake-up from suspend.

## The pieces

| Piece | Role |
|-------|------|
| `/etc/udev/rules.d/99-realtime-audio-optimizer.rules` | Starts the delayed unit when a USB audio interface is added, stops it when one is removed |
| `realtime-audio-optimizer-delayed.service` | Waits for the audio servers of a logged-in user session, then runs the optimization. Stays active (`RemainAfterExit`) so that stopping it restores the system |
| `realtime-audio-optimizer-reapply.service` | Runs the optimization again after the JACK server has started. Members of the `audio` group may start it without a password (polkit rule) |
| `realtime-audio-optimizer.service` | On-demand unit for manual use (`systemctl start/stop`), not started by udev |
| `/usr/lib/systemd/system-sleep/realtime-audio-optimizer` | Runs the delayed optimization again after every wake-up |

All three units are *static*: they have no `[Install]` section and are never
enabled. `systemctl is-enabled` reports `static`, and that is the intended
state — udev, the JACK starter and the sleep hook are the only things that
start them.

## How it works

```
Boot / interface connected
    udev: sound controlC* added, ID_USB_INTERFACES contains ":0102"
      → systemctl start realtime-audio-optimizer-delayed.service
          sleep 15
          wait up to 45 s for PipeWire or JACK of a session of class "user"
          → realtime-audio-optimizer.sh once-delayed
              governors, IRQ affinities, USB autosuspend, kernel parameters,
              all threads of JACK / PipeWire / WirePlumber → AUDIO_MAIN_CPUS

JACK server started (ai-jack-starter or any start script)
      → systemctl start realtime-audio-optimizer-reapply.service
          sleep 2
          → realtime-audio-optimizer.sh once
              pins the real-time threads JACK has just created

Wake-up from suspend
    systemd sleep hook (post)
      → realtime-audio-optimizer.sh once-delayed

Interface removed
    udev: sound card* removed, ID_USB_INTERFACES contains ":0102"
      → systemctl stop realtime-audio-optimizer-delayed.service
          → realtime-audio-optimizer.sh stop
              governors back to DEFAULT_GOVERNOR, process affinity, IRQ
              affinities, kernel parameters and idle states restored
```

### Which devices count

udev records every interface of a USB device in `ID_USB_INTERFACES` as
`:ccsspp:` triples (class, subclass, protocol). An audio interface carries an
Audio Streaming interface, class `01` subclass `02`, so the rules match
`*:0102*`. A MIDI-only controller has only `:010300:` (MIDI Streaming) and
neither starts nor stops the optimizer. The property lives in the udev
database and is still present on the remove event.

```
MOTU M4          ID_USB_INTERFACES=:010120:010220:010100:010300:020200:0a0000:
Korg nanoKEY2    ID_USB_INTERFACES=:010300:
```

With two interfaces connected, removing either one stops the optimizations;
plugging an interface back in starts them again.

### Why the start is delayed

The display manager's login screen runs its own PipeWire and JACK D-Bus
service in a logind session of class `greeter`. Those processes end at login.
A run at boot time that pinned them would leave the user's real audio servers
untouched, and because the delayed unit stays active afterwards, nothing would
try again. The delayed unit therefore counts only processes of sessions of
class `user`, and waits for them.

Measured on the reference system (Intel Core Ultra 7 265, MOTU M4):

| Event | Time after boot |
|-------|-----------------|
| udev: `controlC0` added | 0 s |
| JACK started by ai-jack-starter | +30 s |
| reapply unit finished (started by the starter) | +34 s |
| delayed unit finished (user session detected) | +64 s |

So "instant" is the wrong word. The delay is the price for optimizing the
right processes.

### Why a re-apply after the JACK start

JACK creates its real-time threads only when the server starts, which on most
systems happens after the delayed unit has run. The re-apply unit runs the
optimization once more, and the polkit rule lets the user's start script call
it. `ai-jack-starter` does this after every JACK start; any other start script
can add:

```bash
systemctl start realtime-audio-optimizer-reapply.service
```

The optimization is idempotent, so running it again is always safe.

## CPU governor vs. EPP

`power-profiles-daemon` and the desktop's power management control the Energy
Performance Preference (EPP) of `intel_pstate`, not the governor. EPP alone
was not sufficient for xrun-free operation at low latencies, so the optimizer
sets the `performance` governor explicitly on the audio and IRQ CPUs and keeps
the background E-Cores on `powersave`. `stop` puts every CPU that is on
`performance` back to `DEFAULT_GOVERNOR` (`powersave` unless configured
otherwise) and releases the minimum frequency, so for everyday use the desktop's
power management is back in charge as soon as the interface is unplugged.

## Xrun evaluation

`status`, `live-xruns` and `monitor` share one evaluation:

| Xruns | Status | Recommendation |
|-------|--------|----------------|
| 0 | Optimal | Setup running stable |
| 1-4 | Occasional | Increase buffer if needed |
| 5+ | Frequent | Aggressive buffer / sample rate adjustment |

The recommendation takes the current JACK settings into account:

- 256 samples and few xruns: increase the buffer from 256 to 512
- 128 samples and many xruns: increase the buffer to 1024 or more, or reduce the sample rate
- 2 periods and problems: use 3 periods
- above 48 kHz with xruns: reduce the sample rate to 48 kHz

The JACK parameters (buffer size, sample rate, periods, latency) are read from
the user's session even when the optimizer runs as root: it looks up the
logged-in user and calls `jack_control` and `jack_bufsize` as that user.

## Kernel isolation for the lowest latencies

The IRQ CPUs are taken away from the scheduler on the kernel command line:

```
GRUB_CMDLINE_LINUX="isolcpus=14-19 nohz_full=14-19 rcu_nocbs=14-19 threadirqs preempt=full"
```

| Parameter | Effect |
|-----------|--------|
| `isolcpus=14-19` | The scheduler places no ordinary tasks on these CPUs; they are reserved for the IRQ threads the optimizer pins there |
| `nohz_full=14-19` | No timer tick on these CPUs while a single task runs |
| `rcu_nocbs=14-19` | RCU callbacks are handled elsewhere |
| `threadirqs` | Interrupt handlers run as kernel threads, so they can get SCHED_FIFO priorities |
| `preempt=full` | On kernels built with `PREEMPT_DYNAMIC` (check `/boot/config-$(uname -r)`), switches from voluntary to full preemption at boot |

Adjust the CPU range to `IRQ_CPUS`. Without these parameters the optimizer
still works, but buffers below 64 samples become unreliable. With them, 32
samples at 48 kHz (0.7 ms) run with Yoshimi, and 128 samples carry Organteq
with 35 registers (see the README).

Keep in mind that `isolcpus` is permanent for the boot: nothing else will run
on those CPUs, whether an interface is connected or not. Systems that are also
used for compiling or other parallel workloads may want a second boot entry
without the isolation.

## Manual control

```bash
# Apply / undo by hand (same as udev does)
sudo systemctl start realtime-audio-optimizer-delayed.service
sudo systemctl stop  realtime-audio-optimizer-delayed.service

# Or without systemd
sudo realtime-audio-optimizer once
sudo realtime-audio-optimizer stop

# Read-only diagnosis
realtime-audio-optimizer check
```

## Debugging

```bash
# What the units did
journalctl -b -u realtime-audio-optimizer-delayed -u realtime-audio-optimizer-reapply

# udev side: the rules match the "sound" subsystem, not "usb"
sudo udevadm monitor --property --subsystem-match=sound

# Dry run of the rules for a card: shows the RUN commands without executing them
udevadm test --action=add    /sys/class/sound/controlC0
udevadm test --action=remove /sys/class/sound/card0

# Which interfaces a card exposes
udevadm info -q property -p /sys/class/sound/card0 | grep ID_USB_INTERFACES

# Where the optimizer put the audio server threads
for p in $(pgrep -x jackdbus; pgrep -x pipewire); do taskset -acp $p; done
```

### The interface is connected but nothing was optimized

Check the order of events: `journalctl -b | grep RT-Audio-Optimizer` shows
the udev messages, `journalctl -b -u realtime-audio-optimizer-delayed` shows
whether the unit found a user session. If the unit ran before login it has
optimized the greeter's processes; run the re-apply unit or `once`.

### The optimizations stay after unplugging

The card device must carry `ID_USB_INTERFACES` with `:0102`. Run the
`udevadm test --action=remove` line above for the card and check that the
`systemctl stop` command appears in its output.

### Customizing

```bash
sudo nano /etc/udev/rules.d/99-realtime-audio-optimizer.rules
sudo udevadm control --reload-rules

sudo systemctl edit realtime-audio-optimizer-delayed.service   # drop-in
```
