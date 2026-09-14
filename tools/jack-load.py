#!/usr/bin/env python3
"""jack-load.py — Sample the JACK DSP load reported by jack_cpu_load().

Opens a JACK client without activating it (it takes no part in the process
cycle) and reads the DSP load at a fixed interval.

Usage: jack-load.py [--samples 120] [--interval 0.5] [--summary]

Output:
  n=120 min=1.33% max=1.61% mean=1.45%
  1.4 1.5 1.4 ...          (omitted with --summary)
"""
import argparse
import ctypes
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=120, help="number of samples")
    ap.add_argument("--interval", type=float, default=0.5, help="seconds between samples")
    ap.add_argument("--summary", action="store_true", help="print only the summary line")
    args = ap.parse_args()

    jack = ctypes.CDLL("libjack.so.0")
    jack.jack_client_open.restype = ctypes.c_void_p
    jack.jack_client_open.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
    jack.jack_cpu_load.restype = ctypes.c_float
    jack.jack_cpu_load.argtypes = [ctypes.c_void_p]
    jack.jack_client_close.argtypes = [ctypes.c_void_p]

    client = jack.jack_client_open(b"loadprobe", 1, None)  # JackNoStartServer
    if not client:
        raise SystemExit("no JACK server running")

    values = []
    try:
        for _ in range(args.samples):
            time.sleep(args.interval)
            values.append(jack.jack_cpu_load(client))
    finally:
        jack.jack_client_close(client)

    if not values:
        raise SystemExit("no samples")
    print("n=%d min=%.2f%% max=%.2f%% mean=%.2f%%"
          % (len(values), min(values), max(values), sum(values) / len(values)))
    if not args.summary:
        print(" ".join("%.1f" % v for v in values))


if __name__ == "__main__":
    main()
