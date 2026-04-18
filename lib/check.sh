#!/bin/bash

# Realtime Audio Optimizer - Check Module
# Read-only diagnosis: reports what is correctly configured and what is not
# without making any changes to the system.
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   show_check()
#     Runs a series of read-only checks and prints ✅/❌/⚠️ findings with
#     short fix hints for each problem found.
#     @return : int - 0 if no ❌ findings, 1 otherwise
#     @stdout : Human-readable report
#
# DEPENDENCIES:
#   - config.sh
#   - checks.sh (get_audio_irqs / get_original_user / check_cpu_isolation)
#   - irqs.sh   (check_irq_sharing, get_effective_irq_cpus)
#   - interfaces.sh (detect_usb_audio_interfaces)
#
# ============================================================================

# Tally for final exit code
_CHECK_FAIL_COUNT=0
_CHECK_WARN_COUNT=0
_CHECK_OK_COUNT=0

_check_ok()    { echo "  ✅ $1";                           _CHECK_OK_COUNT=$((_CHECK_OK_COUNT+1)); }
_check_warn()  { echo "  ⚠️  $1"; [ -n "$2" ] && echo "      → $2"; _CHECK_WARN_COUNT=$((_CHECK_WARN_COUNT+1)); }
_check_fail()  { echo "  ❌ $1"; [ -n "$2" ] && echo "      → $2"; _CHECK_FAIL_COUNT=$((_CHECK_FAIL_COUNT+1)); }
_check_section() { echo ""; echo "── $1 ──"; }

# ----------------------------------------------------------------------------
# Individual checks
# ----------------------------------------------------------------------------

_check_kernel_cmdline() {
    _check_section "Kernel boot parameters"
    local cmdline=""
    [ -r /proc/cmdline ] && cmdline=$(cat /proc/cmdline)

    if echo "$cmdline" | grep -qw "threadirqs"; then
        _check_ok "threadirqs is set"
    else
        _check_fail "threadirqs is NOT set" \
            "Add 'threadirqs' to GRUB_CMDLINE_LINUX in /etc/default/grub and run 'sudo update-grub'"
    fi

    if echo "$cmdline" | grep -q "nohz_full="; then
        local v
        v=$(echo "$cmdline" | grep -oE "nohz_full=[^ ]+" | cut -d= -f2)
        _check_ok "nohz_full is set ($v)"
    else
        _check_warn "nohz_full is NOT set" \
            "Optional: add 'nohz_full=<IRQ_CPUS>' to your kernel cmdline for lowest latency"
    fi

    if echo "$cmdline" | grep -q "isolcpus="; then
        local v
        v=$(echo "$cmdline" | grep -oE "isolcpus=[^ ]+" | cut -d= -f2)
        _check_ok "isolcpus is set ($v)"
    else
        _check_warn "isolcpus is NOT set" \
            "Optional: add 'isolcpus=<IRQ_CPUS>' to your kernel cmdline to reserve IRQ cores"
    fi
}

_check_irqbalance() {
    _check_section "irqbalance"
    if pgrep -x irqbalance >/dev/null 2>&1; then
        local banned=""
        if [ -r /etc/default/irqbalance ]; then
            banned=$(grep -E '^[[:space:]]*IRQBALANCE_BANNED_CPUS' /etc/default/irqbalance 2>/dev/null | tail -n1)
        fi
        if [ -n "$banned" ]; then
            _check_ok "irqbalance is running with banned CPUs configured"
        else
            _check_warn "irqbalance is running but no IRQBALANCE_BANNED_CPUS set" \
                "Exclude your RT CPUs in /etc/default/irqbalance (IRQBALANCE_BANNED_CPUS=...)"
        fi
    else
        _check_ok "irqbalance is not running (OK for dedicated IRQ pinning)"
    fi
}

_check_rt_irq_threads() {
    _check_section "IRQ threads / RT scheduling"
    # Look for kernel threads named irq/NNN-* that have SCHED_FIFO (policy FF in ps)
    local rt_irq
    rt_irq=$(ps -eLo pid,class,rtprio,comm 2>/dev/null | awk '$2=="FF" && $4 ~ /^irq\// {c++} END{print c+0}')
    if [ "$rt_irq" -gt 0 ]; then
        _check_ok "$rt_irq IRQ thread(s) running with SCHED_FIFO"
    else
        _check_fail "No IRQ threads with RT priority (SCHED_FIFO) found" \
            "Ensure 'threadirqs' is set and run: sudo realtime-audio-optimizer once"
    fi
}

_check_cpu_governors() {
    _check_section "CPU governors"
    local cpu gov
    local ok=0 bad=0
    # Iterate over known ranges from config (P-Cores + IRQ CPUs expected to be "performance")
    local irq_cpus
    irq_cpus=$(get_effective_irq_cpus 2>/dev/null || echo "$IRQ_CPUS")

    # P-Cores (from DAW_CPUS + AUDIO_MAIN_CPUS ranges -> treat as performance)
    local perf_ranges="$DAW_CPUS $AUDIO_MAIN_CPUS $irq_cpus"
    local cpu_list
    cpu_list=$(_expand_cpu_list "$perf_ranges")

    for cpu in $cpu_list; do
        local file="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor"
        [ -r "$file" ] || continue
        gov=$(cat "$file" 2>/dev/null)
        if [ "$gov" = "performance" ]; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1))
        fi
    done

    if [ "$bad" -eq 0 ] && [ "$ok" -gt 0 ]; then
        _check_ok "All RT-relevant CPUs are on 'performance' governor ($ok CPUs)"
    elif [ "$ok" -eq 0 ] && [ "$bad" -eq 0 ]; then
        _check_warn "Could not read CPU governors (no cpufreq support?)"
    else
        _check_fail "$bad CPU(s) not on 'performance' governor" \
            "Run: sudo realtime-audio-optimizer once"
    fi

    # E-Core background range expected to be powersave
    local bg_list
    bg_list=$(_expand_cpu_list "$BACKGROUND_CPUS")
    local bg_ok=0 bg_bad=0
    for cpu in $bg_list; do
        local file="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor"
        [ -r "$file" ] || continue
        gov=$(cat "$file" 2>/dev/null)
        if [ "$gov" = "$DEFAULT_GOVERNOR" ]; then
            bg_ok=$((bg_ok + 1))
        else
            bg_bad=$((bg_bad + 1))
        fi
    done
    if [ "$bg_bad" -eq 0 ] && [ "$bg_ok" -gt 0 ]; then
        _check_ok "Background CPUs ($BACKGROUND_CPUS) on '$DEFAULT_GOVERNOR' governor"
    elif [ "$bg_ok" -gt 0 ] || [ "$bg_bad" -gt 0 ]; then
        _check_warn "$bg_bad background CPU(s) not on '$DEFAULT_GOVERNOR' governor" \
            "Run: sudo realtime-audio-optimizer once"
    fi
}

_check_usb_autosuspend() {
    _check_section "USB autosuspend (audio devices)"
    local paths found=0 bad=0
    if declare -f get_audio_interface_usb_paths >/dev/null 2>&1; then
        detect_usb_audio_interfaces >/dev/null 2>&1 || true
        paths=$(get_audio_interface_usb_paths 2>/dev/null)
    fi

    if [ -z "$paths" ]; then
        _check_warn "No USB audio interface detected — cannot verify autosuspend"
        return
    fi

    local p
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local ctrl="$p/power/control"
        [ -r "$ctrl" ] || continue
        found=$((found + 1))
        local v
        v=$(cat "$ctrl" 2>/dev/null)
        if [ "$v" = "on" ]; then
            :
        else
            bad=$((bad + 1))
        fi
    done <<< "$paths"

    if [ "$found" -eq 0 ]; then
        _check_warn "Could not read power/control for audio USB devices"
    elif [ "$bad" -eq 0 ]; then
        _check_ok "USB autosuspend disabled for all $found audio device(s)"
    else
        _check_fail "$bad audio USB device(s) have autosuspend enabled" \
            "Run: sudo realtime-audio-optimizer once"
    fi
}

_check_user_groups() {
    _check_section "User groups"
    local user
    user=$(get_original_user)
    [ -z "$user" ] && user=$(whoami)

    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qE '^(audio|realtime)$'; then
        local groups
        groups=$(id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -E '^(audio|realtime)$' | tr '\n' ',' | sed 's/,$//')
        _check_ok "User '$user' is in group(s): $groups"
    else
        _check_fail "User '$user' is not in 'audio' or 'realtime' group" \
            "Run: sudo usermod -aG audio $user  (then log out and back in)"
    fi
}

_check_irq_conflicts() {
    _check_section "IRQ sharing (audio ↔ video)"
    # Capture check_irq_sharing output so we can decide here whether to
    # register this as a proper ❌ finding with a fix hint.
    local out rc
    out=$(check_irq_sharing)
    rc=$?

    if [ $rc -eq 0 ]; then
        _check_ok "No IRQ conflicts between audio and video devices"
    else
        _check_fail "Audio device shares an IRQ with a video device" \
            "Move the devices to different USB ports or USB controllers"
        # Show the original detailed warning(s) as well
        if [ -n "$out" ]; then
            echo "$out" | sed 's/^/      /'
        fi
    fi
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Expand a space-separated list of CPU ranges ("0-5 8 14-19") into individual numbers.
_expand_cpu_list() {
    local input="$1"
    local item start end i
    for item in $input; do
        # Strip quotes if present
        item="${item//\"/}"
        if [[ "$item" == *-* ]]; then
            start="${item%-*}"
            end="${item#*-}"
            # Sanity check that both are integers
            case "$start$end" in
                *[!0-9]*) continue ;;
            esac
            for ((i=start; i<=end; i++)); do
                echo "$i"
            done
        else
            case "$item" in
                ''|*[!0-9]*) continue ;;
            esac
            echo "$item"
        fi
    done
}

# ----------------------------------------------------------------------------
# Public entry point
# ----------------------------------------------------------------------------

show_check() {
    _CHECK_FAIL_COUNT=0
    _CHECK_WARN_COUNT=0
    _CHECK_OK_COUNT=0

    echo "=== $OPTIMIZER_NAME v$OPTIMIZER_VERSION — System Check ==="
    echo "(read-only diagnosis, no changes will be made)"

    _check_kernel_cmdline
    _check_irqbalance
    _check_rt_irq_threads
    _check_cpu_governors
    _check_usb_autosuspend
    _check_user_groups
    _check_irq_conflicts

    echo ""
    echo "── Summary ──"
    echo "  ✅ OK:       $_CHECK_OK_COUNT"
    echo "  ⚠️  Warning:  $_CHECK_WARN_COUNT"
    echo "  ❌ Failed:   $_CHECK_FAIL_COUNT"
    echo ""

    if [ "$_CHECK_FAIL_COUNT" -gt 0 ]; then
        return 1
    fi
    return 0
}
