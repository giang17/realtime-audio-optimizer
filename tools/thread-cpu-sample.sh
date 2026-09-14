#!/bin/bash
# thread-cpu-sample.sh — Sample which CPU each given thread runs on.
#
# Usage: thread-cpu-sample.sh <seconds> <tid> [<tid> ...]
#
# Reads the "processor" field of /proc/<tid>/stat every 50 ms and prints, per
# thread, how many samples fell on each CPU:
#
#   tid 7234: cpu6:1056
#   tid 7243: cpu6:980 cpu7:76

set -u

if [ $# -lt 2 ]; then
    echo "Usage: $0 <seconds> <tid> [<tid> ...]" >&2
    exit 1
fi

duration=$1
shift
end=$((SECONDS + duration))

while [ "$SECONDS" -lt "$end" ]; do
    for tid in "$@"; do
        # The command name may contain spaces; fields after ") " start at
        # field 3, so field 39 (processor) is $37 there
        echo "$tid $(awk '{sub(/.*\) /, ""); print $37}' "/proc/$tid/stat" 2>/dev/null)"
    done
    sleep 0.05
done | sort | uniq -c | awk '{cpus[$2] = cpus[$2] " cpu" $3 ":" $1} END {for (t in cpus) print "tid " t ":" cpus[t]}'
