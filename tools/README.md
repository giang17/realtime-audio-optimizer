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
