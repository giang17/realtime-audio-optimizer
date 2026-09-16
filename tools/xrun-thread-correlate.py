#!/usr/bin/env python3
# xrun-thread-correlate.py — Record where a JACK client's real-time threads
# ran in the 500 ms before and 100 ms after each xrun.
#
# Usage: xrun-thread-correlate.py <seconds> <client-comm> [<jack-log>]
#
# Every 50 ms the state and CPU of every SCHED_FIFO/SCHED_RR thread of the
# client process and of the JACK engine thread (jackdbus, SCHED_FIFO) are
# read from /proc. When a new "XRun" line appears in the jackdbus log, the
# last 10 samples and the next 2 are printed together with the log line.
# The summary at the end gives, per xrun, whether a client thread sat on an
# E-core or on the engine's CPU inside the window, against the baseline
# share of such samples over the whole run.
#
# Machine-specific defaults: E-cores 8-13, engine CPU read from the engine
# thread's affinity at start.

import collections, os, subprocess, sys, time

duration = float(sys.argv[1])
client = sys.argv[2]
jacklog = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.log/jack/jackdbus.log")
ECORES = set(range(8, 14))
INTERVAL = 0.05
BEFORE, AFTER = 10, 2

def pgrep(comm):
    out = subprocess.run(["pgrep", "-x", comm], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]

def rt_threads(pid):
    """(tid, comm, policy) for threads with SCHED_FIFO(1) or SCHED_RR(2)."""
    res = []
    try:
        for tid in os.listdir(f"/proc/{pid}/task"):
            with open(f"/proc/{pid}/task/{tid}/stat") as f:
                s = f.read()
            comm = s[s.index("(") + 1:s.rindex(")")]
            fields = s[s.rindex(")") + 2:].split()
            policy = int(fields[38])          # field 41 overall
            if policy in (1, 2):
                res.append((int(tid), comm, policy))
    except (FileNotFoundError, ProcessLookupError):
        pass
    return res

def sample(tid):
    try:
        with open(f"/proc/{tid}/stat") as f:
            s = f.read()
        fields = s[s.rindex(")") + 2:].split()
        return fields[0], int(fields[36])    # state, processor
    except (FileNotFoundError, ProcessLookupError):
        return "-", -1

pids = pgrep(client)
if not pids:
    sys.exit(f"no process named {client}")
pid = pids[0]
jack = pgrep("jackdbus")
engine = [t for t in rt_threads(jack[0]) if t[2] == 1] if jack else []
engine_tid = engine[0][0] if engine else None
engine_cpu = None
if engine_tid:
    aff = subprocess.run(["taskset", "-cp", str(engine_tid)], capture_output=True, text=True).stdout
    engine_cpu = aff.rsplit(":", 1)[1].strip()

threads = rt_threads(pid)
print(f"client {client} pid {pid}, RT threads: " + ", ".join(f"{c}({t},{'FIFO' if p == 1 else 'RR'})" for t, c, p in threads))
print(f"engine thread {engine_tid} on CPU {engine_cpu}; E-cores {sorted(ECORES)}; window {BEFORE * INTERVAL * 1000:.0f} ms before / {AFTER * INTERVAL * 1000:.0f} ms after")
print(f"jack log {jacklog}", flush=True)

ring = collections.deque(maxlen=BEFORE)
pending = []            # xruns waiting for AFTER samples: [line, samples_after]
xruns = []              # (line, list_of_samples)
total = ecore_hits = engine_hits = 0
logpos = os.path.getsize(jacklog) if os.path.exists(jacklog) else 0
t_end = time.monotonic() + duration
last_refresh = 0

def fmt(s):
    ts, rows = s
    parts = []
    for comm, st, cpu in rows:
        tag = "E" if cpu in ECORES else ("J" if str(cpu) == engine_cpu else "")
        parts.append(f"{comm}:{st}{cpu}{tag}")
    return f"  {ts:%H:%M:%S}.{ts.microsecond // 1000:03d}  " + " ".join(parts)

import datetime
while time.monotonic() < t_end:
    now = datetime.datetime.now()
    if time.monotonic() - last_refresh > 5:
        threads = rt_threads(pid) or threads
        last_refresh = time.monotonic()
    rows = []
    for tid, comm, pol in threads:
        st, cpu = sample(tid)
        rows.append((f"{comm}/{'F' if pol == 1 else 'R'}", st, cpu))
        if cpu >= 0:
            total += 1
            if cpu in ECORES: ecore_hits += 1
            if str(cpu) == engine_cpu: engine_hits += 1
    if engine_tid:
        st, cpu = sample(engine_tid)
        rows.append(("engine", st, cpu))
    s = (now, rows)
    ring.append(s)
    for p in pending:
        p[1].append(s)
    done = [p for p in pending if len(p[1]) >= AFTER]
    for p in done:
        pending.remove(p)
        xruns.append((p[0], p[2] + p[1]))
        print(f"\nXRUN #{len(xruns)}  {p[0]}")
        for row in p[2] + p[1]:
            print(fmt(row))
        print(flush=True)
    # new log lines?
    try:
        size = os.path.getsize(jacklog)
        if size > logpos:
            with open(jacklog, errors="replace") as f:
                f.seek(logpos)
                new = f.read()
            logpos = size
            for line in new.splitlines():
                if "XRun" in line:
                    line = line.replace("\x1b[1m\x1b[31m", "").replace("\x1b[0m", "")
                    pending.append([line, [], list(ring)])
        elif size < logpos:
            logpos = size
    except FileNotFoundError:
        pass
    time.sleep(INTERVAL)

print("\n=== summary ===")
print(f"samples {total}: on E-core {100 * ecore_hits / max(total, 1):.1f} %, on engine CPU {100 * engine_hits / max(total, 1):.1f} %")
print(f"xruns {len(xruns)}")
for i, (line, rows) in enumerate(xruns, 1):
    e = sum(1 for _, r in rows for comm, st, cpu in r if comm != "engine" and cpu in ECORES)
    j = sum(1 for _, r in rows for comm, st, cpu in r if comm != "engine" and str(cpu) == engine_cpu)
    n = sum(1 for _, r in rows for comm, *_ in r if comm != "engine")
    print(f"  #{i} {line.split(': ', 1)[-1][:70]}  client samples in window: {n}, on E-core {e}, on engine CPU {j}")
