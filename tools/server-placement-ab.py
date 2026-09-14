#!/usr/bin/env python3
"""server-placement-ab.py — A/B measurement of the JACK DSP load for the CPU
placement of the audio server threads.

Moves all threads of jackdbus/jackd, PipeWire, PipeWire-Pulse and WirePlumber
of the current user between two CPU sets, phase by phase, and reports per
phase:

  - JACK DSP load (jack_cpu_load every 0.5 s): mean, p95, maximum
  - xruns: JACK xrun callback and "xrun" lines in the user journal
  - where the JACK engine thread and PipeWire's JACK tunnel thread ran
    (sampled every 50 ms)

Only the CPU affinity is changed, not the scheduling; no root needed. The
placement stays as set by the last phase until the next optimizer run
(systemctl start realtime-audio-optimizer-reapply.service).

Usage: server-placement-ab.py [--phases 1,2,1,2] [--secs 60] [--one 6] [--two 6-7]
"""
import argparse
import ctypes
import os
import subprocess
import threading
import time
from collections import Counter

SERVER_NAMES = ("jackdbus", "jackd", "pipewire", "pipewire-pulse", "wireplumber")


def pids_by_name(name):
    out = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", name],
                         capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def thread_info(pid, tid):
    """(comm, policy, rt_priority, last_cpu) from /proc/<pid>/task/<tid>/stat."""
    try:
        with open(f"/proc/{pid}/task/{tid}/stat") as f:
            stat = f.read()
    except OSError:
        return None
    comm = stat[stat.index("(") + 1:stat.rindex(")")]
    rest = stat[stat.rindex(")") + 2:].split()
    # rest[0] is field 3, so field N is rest[N - 3]
    return comm, int(rest[41 - 3]), int(rest[40 - 3]), int(rest[39 - 3])


def server_threads():
    """All server threads plus the JACK engine and PipeWire JACK tunnel thread."""
    all_tids, jack_tid, tunnel_tid = [], None, None
    for name in SERVER_NAMES:
        for pid in pids_by_name(name):
            for tid in (int(t) for t in os.listdir(f"/proc/{pid}/task")):
                info = thread_info(pid, tid)
                if not info:
                    continue
                all_tids.append((pid, tid))
                comm, policy, _, _ = info
                if policy not in (1, 2):
                    continue
                if name in ("jackdbus", "jackd") and jack_tid is None:
                    jack_tid = (pid, tid)
                # The JACK tunnel is the real-time thread in PipeWire that is
                # not pw-data-loop
                if name == "pipewire" and comm != "pw-data-loop" and tunnel_tid is None:
                    tunnel_tid = (pid, tid)
    return all_tids, jack_tid, tunnel_tid


def pin(tids, cpus):
    for _, tid in tids:
        subprocess.run(["taskset", "-cp", cpus, str(tid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def journal_xruns(since):
    out = subprocess.run(["journalctl", "--user", "--since", since, "--no-pager", "-q"],
                         capture_output=True, text=True).stdout
    return sum(1 for line in out.splitlines() if "xrun" in line.lower())


def other_jack_clients():
    out = subprocess.run(["jack_lsp"], capture_output=True, text=True, timeout=5).stdout
    names = {line.split(":", 1)[0] for line in out.splitlines() if ":" in line}
    return sorted(names - {"system", "PipeWire", "ab-loadprobe"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phases", default="1,2,1,2", help="sequence of 1 (--one) and 2 (--two)")
    ap.add_argument("--secs", type=int, default=60, help="seconds per phase")
    ap.add_argument("--one", default="6", help="CPUs for phase 1")
    ap.add_argument("--two", default="6-7", help="CPUs for phase 2")
    args = ap.parse_args()

    jack = ctypes.CDLL("libjack.so.0")
    jack.jack_client_open.restype = ctypes.c_void_p
    jack.jack_client_open.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
    jack.jack_cpu_load.restype = ctypes.c_float
    jack.jack_cpu_load.argtypes = [ctypes.c_void_p]
    xrun_cb_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
    jack.jack_set_xrun_callback.argtypes = [ctypes.c_void_p, xrun_cb_type, ctypes.c_void_p]
    jack.jack_activate.argtypes = [ctypes.c_void_p]
    jack.jack_client_close.argtypes = [ctypes.c_void_p]

    client = jack.jack_client_open(b"ab-loadprobe", 1, None)  # JackNoStartServer
    if not client:
        raise SystemExit("no JACK server running")
    xruns = [0]
    lock = threading.Lock()

    def on_xrun(_arg):
        with lock:
            xruns[0] += 1
        return 0

    xrun_cb = xrun_cb_type(on_xrun)  # keep a reference for the callback's lifetime
    jack.jack_set_xrun_callback(client, xrun_cb, None)
    jack.jack_activate(client)

    all_tids, jack_tid, tunnel_tid = server_threads()
    print(f"Threads: {len(all_tids)}, JACK engine tid={jack_tid and jack_tid[1]}, "
          f"tunnel tid={tunnel_tid and tunnel_tid[1]}")

    try:
        for n, phase in enumerate(args.phases.split(","), 1):
            cpus = args.one if phase.strip() == "1" else args.two
            all_tids, jack_tid, tunnel_tid = server_threads()  # servers may have restarted
            pin(all_tids, cpus)
            # jack_cpu_load is smoothed; let the previous placement drain
            time.sleep(2)
            others = other_jack_clients()
            since = time.strftime("%Y-%m-%d %H:%M:%S")
            with lock:
                x0 = xruns[0]
            loads, where = [], Counter()
            t_end = time.monotonic() + args.secs
            next_load = time.monotonic()
            while time.monotonic() < t_end:
                if time.monotonic() >= next_load:
                    loads.append(jack.jack_cpu_load(client))
                    next_load += 0.5
                for label, key in (("jack", jack_tid), ("tunnel", tunnel_tid)):
                    if key:
                        info = thread_info(*key)
                        if info:
                            where[(label, info[3])] += 1
                time.sleep(0.05)
            with lock:
                jack_xruns = xruns[0] - x0
            loads.sort()
            p95 = loads[max(int(len(loads) * 0.95) - 1, 0)] if loads else 0.0
            mean = sum(loads) / len(loads) if loads else 0.0
            dist = " ".join(f"{label}@cpu{cpu}:{count}" for (label, cpu), count in sorted(where.items()))
            print(f"Phase {n} [{phase} -> CPUs {cpus}]  {time.strftime('%H:%M:%S')}  "
                  f"load mean={mean:.2f}% p95={p95:.2f}% max={loads[-1] if loads else 0:.2f}%  "
                  f"JACK xruns={jack_xruns} journal xruns={journal_xruns(since)}  "
                  f"other JACK clients={others or 'none'}\n    {dist}", flush=True)
    finally:
        jack.jack_client_close(client)


if __name__ == "__main__":
    main()
