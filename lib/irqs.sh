#!/bin/bash

# Realtime Audio Optimizer - IRQ Module
# Dynamic IRQ detection, CPU selection and IRQ-sharing diagnostics.
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   detect_audio_irqs()
#     Finds IRQs for currently connected audio (sound) devices by walking
#     /sys/class/sound/card*/device (and parents) for 'irq' and 'msi_irqs'.
#     Falls back to /proc/interrupts "snd_*" parsing if sysfs yields nothing.
#     @return : string - Space-separated list of unique IRQ numbers
#
#   detect_video_irqs()
#     Finds IRQs for video4linux devices (webcams, capture cards) by walking
#     /sys/class/video4linux/video*/device and parents for 'irq'/'msi_irqs'.
#     @return : string - Space-separated list of unique IRQ numbers
#
#   detect_best_irq_cpus()
#     Determines the best CPU range for IRQ handling on the running system.
#     Priority order:
#       1. E-Cores reported via /sys/.../topology/core_type == "atom"
#          (Intel hybrid CPUs: Alder/Raptor/Arrow Lake)
#       2. Last quarter of online CPUs (dedicated IRQ cores on non-hybrid)
#       3. Fallback to $IRQ_CPUS from config.sh (static behavior)
#     @return : string - CPU list like "14-19" or "4-7"
#     @stderr : Debug info about detection path taken
#
#   get_effective_irq_cpus()
#     Returns the IRQ CPU list that should actually be used.
#     Caches the result in EFFECTIVE_IRQ_CPUS after first call.
#     Honors RT_AUDIO_DYNAMIC_IRQS=false to force the static config value.
#     @return : string - CPU list
#
#   check_irq_sharing()
#     Detects if any audio IRQ is shared with a video IRQ (common USB root
#     hub contention with webcams). Prints a human-readable warning block
#     to stdout for each conflict.
#     @return : int - 0 if no conflict, 1 if one or more conflicts detected
#
# DEPENDENCIES:
#   - config.sh (IRQ_CPUS)
#   - logging.sh (log_debug) [optional]
#
# ============================================================================

# Cached value of the effective IRQ CPU range (populated by get_effective_irq_cpus)
EFFECTIVE_IRQ_CPUS=""

# ----------------------------------------------------------------------------
# Internal: collect IRQ numbers from a sysfs device directory (walks parents)
# ----------------------------------------------------------------------------
_irqs_for_sysfs_device() {
    local dev="$1"
    [ -d "$dev" ] || return 0

    local real
    real=$(readlink -f "$dev" 2>/dev/null) || return 0

    local current="$real"
    # Walk up until we find a node with irq / msi_irqs (usually PCI parent)
    while [ -n "$current" ] && [ "$current" != "/" ] && [ "$current" != "/sys" ]; do
        if [ -f "$current/irq" ]; then
            local irq
            irq=$(cat "$current/irq" 2>/dev/null)
            if [ -n "$irq" ] && [ "$irq" != "0" ]; then
                echo "$irq"
            fi
        fi
        if [ -d "$current/msi_irqs" ]; then
            local f
            for f in "$current/msi_irqs"/*; do
                [ -e "$f" ] || continue
                local nr
                nr=$(basename "$f")
                case "$nr" in
                    ''|*[!0-9]*) continue ;;
                esac
                echo "$nr"
            done
        fi
        current=$(dirname "$current")
    done
}

# ----------------------------------------------------------------------------
# Detect audio IRQs dynamically from /sys/class/sound
# ----------------------------------------------------------------------------
detect_audio_irqs() {
    local irqs=""
    local card

    for card in /sys/class/sound/card*; do
        [ -e "$card" ] || continue
        # Only cards that actually have a PCM subdirectory are "active"
        local has_pcm=false
        local sub
        for sub in "$card"/pcm*; do
            if [ -e "$sub" ]; then
                has_pcm=true
                break
            fi
        done
        $has_pcm || continue

        if [ -e "$card/device" ]; then
            local found
            found=$(_irqs_for_sysfs_device "$card/device")
            [ -n "$found" ] && irqs="$irqs $found"
        fi
    done

    # Fallback: parse /proc/interrupts for snd_/audio if sysfs yielded nothing
    if [ -z "${irqs// }" ]; then
        if [ -r /proc/interrupts ]; then
            local parsed
            parsed=$(grep -iE "snd_|audio|usb-audio" /proc/interrupts 2>/dev/null \
                     | awk '{gsub(":",""); print $1}' \
                     | grep -E '^[0-9]+$')
            irqs="$parsed"
        fi
    fi

    # Uniquify, space-separated
    echo "$irqs" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' | sed 's/ *$//'
}

# ----------------------------------------------------------------------------
# Detect video device IRQs from /sys/class/video4linux
# ----------------------------------------------------------------------------
detect_video_irqs() {
    local irqs=""

    [ -d /sys/class/video4linux ] || { echo ""; return 0; }

    local vdev
    for vdev in /sys/class/video4linux/video*; do
        [ -e "$vdev" ] || continue
        if [ -e "$vdev/device" ]; then
            local found
            found=$(_irqs_for_sysfs_device "$vdev/device")
            [ -n "$found" ] && irqs="$irqs $found"
        fi
    done

    echo "$irqs" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' | sed 's/ *$//'
}

# ----------------------------------------------------------------------------
# Pick best IRQ CPUs based on runtime topology
# ----------------------------------------------------------------------------
detect_best_irq_cpus() {
    local e_cores=""
    local cpu
    local topo_file

    # Probe intel-pstate hybrid topology: core_type is "atom" (E) or "core" (P)
    for topo_file in /sys/devices/system/cpu/cpu[0-9]*/topology/core_type; do
        [ -r "$topo_file" ] || continue
        local kind
        kind=$(cat "$topo_file" 2>/dev/null)
        if [ "$kind" = "atom" ]; then
            local cpu_dir
            cpu_dir=$(dirname "$(dirname "$topo_file")")
            cpu=$(basename "$cpu_dir")
            cpu="${cpu#cpu}"
            case "$cpu" in
                ''|*[!0-9]*) continue ;;
            esac
            e_cores="$e_cores $cpu"
        fi
    done

    if [ -n "${e_cores// }" ]; then
        # Use the *upper half* of E-Cores for IRQ handling
        # (leaves lower E-Cores free for background tasks — matches existing strategy)
        local sorted
        sorted=$(echo "$e_cores" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n)
        local count
        count=$(echo "$sorted" | wc -l)
        if [ "$count" -ge 2 ]; then
            local half=$((count / 2))
            local upper
            upper=$(echo "$sorted" | tail -n "$((count - half))")
            local first last
            first=$(echo "$upper" | head -n1)
            last=$(echo "$upper" | tail -n1)
            echo "${first}-${last}"
            return 0
        else
            # Only one E-Core: use it alone
            echo "$(echo "$sorted" | head -n1)"
            return 0
        fi
    fi

    # Non-hybrid fallback: use last quarter of online CPUs
    local online_count
    online_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
    if [ "$online_count" -ge 4 ]; then
        local reserve=$(( online_count / 4 ))
        [ "$reserve" -lt 1 ] && reserve=1
        local start=$(( online_count - reserve ))
        local end=$(( online_count - 1 ))
        if [ "$start" -lt "$end" ]; then
            echo "${start}-${end}"
            return 0
        elif [ "$start" -eq "$end" ] && [ "$start" -ge 0 ]; then
            echo "${start}"
            return 0
        fi
    fi

    # Absolute fallback: static config value
    echo "$IRQ_CPUS"
    return 0
}

# ----------------------------------------------------------------------------
# Public: effective IRQ CPU range (cached)
# ----------------------------------------------------------------------------
get_effective_irq_cpus() {
    # Honor opt-out
    if [ "${RT_AUDIO_DYNAMIC_IRQS:-true}" = "false" ]; then
        echo "$IRQ_CPUS"
        return 0
    fi

    if [ -n "$EFFECTIVE_IRQ_CPUS" ]; then
        echo "$EFFECTIVE_IRQ_CPUS"
        return 0
    fi

    local detected
    detected=$(detect_best_irq_cpus 2>/dev/null)

    if [ -z "$detected" ]; then
        detected="$IRQ_CPUS"
    fi

    EFFECTIVE_IRQ_CPUS="$detected"
    if declare -f log_debug >/dev/null 2>&1; then
        if [ "$detected" = "$IRQ_CPUS" ]; then
            log_debug "IRQ CPUs: using static config value '$IRQ_CPUS'"
        else
            log_debug "IRQ CPUs: dynamically detected '$detected' (config was '$IRQ_CPUS')"
        fi
    fi
    echo "$detected"
}

# ----------------------------------------------------------------------------
# IRQ sharing check (audio vs video)
# ----------------------------------------------------------------------------
check_irq_sharing() {
    local audio_irqs video_irqs
    audio_irqs=$(detect_audio_irqs)
    video_irqs=$(detect_video_irqs)

    if [ -z "${audio_irqs// }" ] || [ -z "${video_irqs// }" ]; then
        return 0
    fi

    local conflicts=0
    local a v
    for a in $audio_irqs; do
        for v in $video_irqs; do
            if [ "$a" = "$v" ]; then
                local audio_name="audio device"
                local video_name="video device"

                # Try to recover friendly names
                local c
                for c in /sys/class/sound/card*; do
                    [ -e "$c/device" ] || continue
                    local cirqs
                    cirqs=$(_irqs_for_sysfs_device "$c/device")
                    if echo " $cirqs " | grep -q " $a "; then
                        if [ -r "$c/id" ]; then
                            audio_name=$(cat "$c/id" 2>/dev/null)
                        fi
                        break
                    fi
                done

                local vd
                for vd in /sys/class/video4linux/video*; do
                    [ -e "$vd/device" ] || continue
                    local virqs
                    virqs=$(_irqs_for_sysfs_device "$vd/device")
                    if echo " $virqs " | grep -q " $v "; then
                        if [ -r "$vd/name" ]; then
                            video_name=$(cat "$vd/name" 2>/dev/null)
                        else
                            video_name=$(basename "$vd")
                        fi
                        break
                    fi
                done

                echo "⚠️  WARNING: Audio device '$audio_name' shares a USB controller/IRQ (#$a) with video device '$video_name'"
                echo "    → This can cause audio dropouts and latency spikes."
                echo "    → Fix: Move the devices to different USB ports or USB controllers."
                conflicts=$((conflicts + 1))
            fi
        done
    done

    [ "$conflicts" -eq 0 ] && return 0
    return 1
}
