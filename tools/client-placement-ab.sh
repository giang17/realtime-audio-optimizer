#!/bin/bash
# client-placement-ab.sh — A/B measurement of the JACK DSP load for the CPU
# placement of a JACK client's real-time threads.
#
# Usage: client-placement-ab.sh <process name | PID> [phases] [seconds]
#
#   phases: comma-separated, each one of
#     free  - all real-time threads of the client on FREE_CPUS
#     cb    - only the JACK callback thread(s) on AUDIO_CPU (the CPU of the
#             JACK engine), the other real-time threads on FREE_CPUS
#     all   - all real-time threads of the client on AUDIO_CPU
#   default: free,cb,free,cb   60
#
# Environment: AUDIO_CPU (default 6), FREE_CPUS (default: all online CPUs).
#
# The JACK callback thread is recognized by SCHED_FIFO at the JACK server's
# realtime-priority minus 5 (the priority libjack gives client threads).
# Server threads are not touched. At the end all client threads go back to
# FREE_CPUS. Long process names are truncated to 15 characters in comm; pass
# the PID then (e.g. Bitwig's "BitwigAudioEngine-X64-AVX2").
#
# Be careful with "all" for multi-threaded clients: Bitwig runs 20 real-time
# worker threads that together used about 86 % of one CPU.

TOOLS=$(cd "$(dirname "$0")" && pwd)
TARGET="$1"
PHASES="${2:-free,cb,free,cb}"
SECS="${3:-60}"
AUDIO_CPU="${AUDIO_CPU:-6}"
JACK_LOG="$HOME/.log/jack/jackdbus.log"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <process name | PID> [phases] [seconds]" >&2
    exit 1
fi

case "$TARGET" in
    *[!0-9]*) PID=$(pgrep -u "$(id -u)" -x "$TARGET" | head -1) ;;
    *)        PID="$TARGET" ;;
esac
if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
    echo "Process '$TARGET' is not running" >&2
    exit 1
fi
NAME=$(cat "/proc/$PID/comm")

# Default: the CPUs the client's main thread may use - not all online CPUs,
# which would include CPUs isolated with isolcpus
FREE_CPUS="${FREE_CPUS:-$(taskset -cp "$PID" | sed 's/.*: //')}"

# Scheduling policy ($39) and priority ($38) of a thread; comm may contain spaces
sched_of() {
    local stat
    stat=$(cat "$1" 2>/dev/null) || return 1
    # shellcheck disable=SC2086
    set -- ${stat##*) }
    echo "${39} ${38}"
}

rt_threads() {   # "tid policy priority" of all real-time threads of the client
    local task info
    for task in /proc/"$PID"/task/*; do
        info=$(sched_of "$task/stat") || continue
        case "${info%% *}" in
            1|2) echo "${task##*/} $info" ;;
        esac
    done
}

jack_xruns() {
    [ -r "$JACK_LOG" ] || { echo 0; return; }
    grep -c 'JackEngine::XRun' "$JACK_LOG"
}

other_clients() {
    timeout 5 jack_lsp 2>/dev/null | sed 's/:.*//' | sort -u | \
        grep -vxE "system|PipeWire|loadprobe|$(printf '%s' "$NAME" | sed 's/[.[\*^$]/\\&/g')" | paste -sd, -
}

JACK_PRIO=$(timeout 5 jack_control ep 2>/dev/null | sed -n 's/.*realtime-priority.*:\([0-9]*\))$/\1/p')
CB_PRIO=$(( ${JACK_PRIO:-10} - 5 ))

JACK_TID=""
for pid in $(pgrep -u "$(id -u)" -x jackdbus) $(pgrep -u "$(id -u)" -x jackd); do
    for task in /proc/"$pid"/task/*; do
        [ "$(sched_of "$task/stat" | cut -d' ' -f1)" = 1 ] && { JACK_TID=${task##*/}; break 2; }
    done
done

echo "Client $NAME (PID $PID), JACK engine tid=${JACK_TID:-?}, callback priority=$CB_PRIO, AUDIO_CPU=$AUDIO_CPU, FREE_CPUS=$FREE_CPUS"
CB_TIDS=$(rt_threads | awk -v p="$CB_PRIO" '$2 == 1 && $3 == p {print $1}')
ALL_TIDS=$(rt_threads | awk '{print $1}')
[ -n "$CB_TIDS" ] || echo "WARNING: no callback thread with SCHED_FIFO $CB_PRIO found"
FIRST_CB=$(echo "$CB_TIDS" | head -1)

for phase in ${PHASES//,/ }; do
    for tid in $ALL_TIDS; do taskset -cp "$FREE_CPUS" "$tid" > /dev/null 2>&1; done
    case "$phase" in
        free) ;;
        cb)   for tid in $CB_TIDS;  do taskset -cp "$AUDIO_CPU" "$tid" > /dev/null 2>&1; done ;;
        all)  for tid in $ALL_TIDS; do taskset -cp "$AUDIO_CPU" "$tid" > /dev/null 2>&1; done ;;
        *)    echo "unknown phase '$phase'" >&2; continue ;;
    esac

    # jack_cpu_load is smoothed; let the previous placement drain
    sleep 3
    since=$(date '+%Y-%m-%d %H:%M:%S')
    others=$(other_clients)
    x0=$(jack_xruns)

    sample_file=$(mktemp)
    # shellcheck disable=SC2086
    "$TOOLS/thread-cpu-sample.sh" $((SECS - 2)) $JACK_TID $FIRST_CB > "$sample_file" &
    result=$("$TOOLS/jack-load.py" --samples $((SECS * 2)) --summary)
    wait

    x1=$(jack_xruns)
    jx=$(journalctl --user --since "$since" --no-pager -q 2>/dev/null | grep -ci xrun)
    echo "$phase  $(date +%T)  $result  jackdbus xruns=$((x1 - x0)) journal xruns=$jx  other JACK clients=${others:-none}"
    sed 's/^/    /' "$sample_file"
    rm -f "$sample_file"
done

for tid in $ALL_TIDS; do taskset -cp "$FREE_CPUS" "$tid" > /dev/null 2>&1; done
echo "Done $(date +%T), client threads back on $FREE_CPUS"
