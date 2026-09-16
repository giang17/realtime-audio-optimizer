# Measurement tools

Tools used to measure how thread placement affects the JACK DSP load. They
are not installed by `install.sh`; run them from the repository. None of them
needs root: CPU affinity of your own threads can be changed as a normal user.

| Tool | Purpose |
|------|---------|
| `jack-load.py` | Sample `jack_cpu_load()` at a fixed interval, print min/max/mean |
| `thread-cpu-sample.sh` | Sample which CPU given threads run on (every 50 ms) |
| `server-placement-ab.py` | Alternate all JACK/PipeWire server threads between two CPU sets, measure each phase |
| `client-placement-ab.sh` | Alternate a JACK client's real-time threads between free placement and the JACK engine's CPU |
| `xrun-thread-correlate.py` | Record where a client's real-time threads ran in the 500 ms before each xrun |

## Usage

```bash
# Idle load for 60 s
tools/jack-load.py --samples 120

# Server threads: CPU 6 vs CPUs 6-7, four 60 s phases
tools/server-placement-ab.py --phases 1,2,1,2 --secs 60 --one 6 --two 6-7

# A client: callback thread free vs on the JACK engine's CPU
AUDIO_CPU=6 tools/client-placement-ab.sh Pianoteq free,cb,free,cb 45

# Long process names are truncated to 15 characters: pass the PID
tools/client-placement-ab.sh "$(pgrep -u "$USER" BitwigAudioEngi | head -1)"

# Xruns: sample the client's RT threads every 50 ms for 15 min, dump the
# window around each "XRun" line of the jackdbus log
tools/xrun-thread-correlate.py 900 Pianoteq
```

`server-placement-ab.py` leaves the server threads in the placement of the
last phase, `client-placement-ab.sh` puts the client threads back on
`FREE_CPUS`. To restore the optimizer's placement afterwards:

```bash
systemctl start realtime-audio-optimizer-reapply.service
```

## What the number means

`jack_cpu_load()` reports how much of the JACK period the recent cycles
needed. It is not a CPU usage figure: waiting for a thread on another CPU to
wake up counts as well. Idle on the system below, PipeWire's JACK tunnel
needed about 8 µs per cycle (`pw-top`), while the reported load moved between
1.5 % (40 µs) and 9.4 % (250 µs) depending only on where the threads ran.

## Pitfalls seen during the measurements

- **Other JACK clients falsify a phase.** A synth started by accident during
  a 60 s phase raised it from 1.5 % to 13 %. The A/B tools print the other
  JACK clients per phase; check them before comparing numbers.
- **The value is smoothed.** Right after a placement change the first
  samples still carry the previous state (one phase had a minimum of 3.9 %
  and a mean of 12.9 %). The tools wait 2–3 s before sampling; compare
  repeated phases, not the first one alone.
- **Idle and load behave differently.** Two CPUs instead of one for the
  servers cost 8 points idle but 0.4 points with a synth playing. Measure
  the case you care about.
- **Be careful with "all" for multi-threaded clients.** Bitwig runs 20
  real-time worker threads that together used about 86 % of one CPU; the
  "all" phase would put them next to the JACK engine. It was not measured.
- **Changing C-states needs root** and is not done by these tools:
  `echo 0 | sudo tee /sys/devices/system/cpu/cpu6/cpuidle/state3/disable`
  (1 = disable again).
- **`/proc/<tid>/sched` wait statistics are unusable for real-time threads
  that migrate.** With `kernel.sched_schedstats=1`, `wait_max` of Pianoteq's
  workers jumped to the system uptime within milliseconds of a reset
  (`echo 0 > /proc/<tid>/sched`), with only 3-5 wait samples counted, so
  some enqueue path of migrating RT threads leaves the wait start stamp at
  zero (kernel 6.17; not traced in the source). `nr_involuntary_switches` is
  still valid.
- **50 ms sampling cannot see a 2.7 ms period.** The xrun tool shows the
  placement tendency around an xrun, not the xrun period itself; use it to
  rank hypotheses, then test them with the xrun rate.

## Results

Intel Core Ultra 7 265, JACK 128 frames / 48 kHz / 2 periods, MOTU M4,
PipeWire JACK tunnel, 0.5 s samples:

| Condition | JACK DSP load |
|-----------|---------------|
| Idle: JACK engine, tunnel and pw-data-loop on one CPU | 1.5 % |
| Idle: engine and tunnel on one CPU, pw-data-loop on another | 5.5 % |
| Idle: engine and tunnel on two CPUs | 9.4 % |
| Idle, all on one CPU: C3 allowed / disabled | 1.56 % / 1.49 % |
| Pianoteq 9 playing: servers on one / two CPUs | 15.2 % / 15.6 % |
| Pianoteq 9 playing: its callback free / on the engine's CPU | 15.4 % / 11.0 % |
| Pianoteq 9 playing: callback on another CPU with C3 disabled | 15.8 % |
| Bitwig demo song: callback free / on the engine's CPU | 24.1 % / 22.6 % (within drift) |

### Xruns of a multi-threaded client (2026-09-16)

Pianoteq 9 with "Multicore rendering: max" runs its JACK callback (SCHED_FIFO 5)
and five workers `fasthp-1..5` (SCHED_RR 64), affinity 0-13, all woken every
period. Its demo song at 128 frames produced xruns reported as
`client = Pianoteq was not finished` at about 1.3 per minute, with the servers
on CPU 6 and the DSP load at 20-25 %.

Measured with `xrun-thread-correlate.py` (14 xruns, 10 min) and `/proc`
counters:

- The JACK engine's CPU is not involved: client samples on CPU 6 were 7.1 %
  overall and 9.8 % in the xrun windows, and the engine thread was asleep in
  nearly every sample.
- E-cores 8-13 contribute a little: 9.5 % of all client samples, 12 % in the
  windows, 17-20 % in two of them.
- The callback thread had 1.24 million involuntary context switches, about
  two per period. IRQ threads were not involved (no CPU time, device
  interrupts on CPUs 0-13 in the range of one per second), which leaves its
  own workers (RR 64 > FIFO 5) landing on its CPU as the only higher-priority
  real-time threads that ran.
- The worker CPUs entered C3 800-1000 times per second, two to three times
  per period, with a 1048 µs exit latency against a 2667 µs period.

| Condition (demo song, same settings) | Xruns |
|--------------------------------------|-------|
| C3 allowed on CPUs 0-7, 10 min | 13 (1.3/min) |
| C3 disabled on CPUs 0-7, 5 min | 3 (0.6/min) |

So the C-state limit that made no difference for the server threads (table
above) halves the xruns of a client whose workers wake from C3 every period.
This is why `CSTATE_LIMIT_CPUS="0-7"` is a documented option; the E-cores
keep every idle state, which leaves the workers' 9.5 % of samples there as
the next candidate (pin the client to 0-7 via `EXTRA_AUDIO_PROCESSES`).
