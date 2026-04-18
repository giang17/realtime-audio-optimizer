#!/bin/bash

# Realtime Audio Optimizer - Optimization Module
# Contains main activation and deactivation functions for audio optimizations
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   activate_audio_optimizations()
#     Main entry point for enabling all audio optimizations.
#     @return   : void
#     @requires : Root privileges
#
#   deactivate_audio_optimizations()
#     Reverts all optimizations to system defaults.
#     @return   : void
#     @requires : Root privileges
#
#   count_optimized_usb_irqs()
#     Counts USB IRQs pinned to IRQ E-Cores.
#     @return : string - "optimized/total" (e.g., "3/3")
#
#   count_optimized_audio_irqs()
#     Counts audio IRQs pinned to IRQ E-Cores.
#     @return : string - "optimized/total" (e.g., "2/2")
#
#   is_system_optimized()
#     Checks if optimizations are currently active.
#     @exit   : 0 if optimized, 1 if not
#
# HYBRID STRATEGY CPU LAYOUT:
#
#   CPUs 0-7   (P-Cores)      : Performance governor, audio processing
#   CPUs 8-13  (E-Cores BG)   : Powersave governor, background tasks
#   CPUs 14-19 (E-Cores IRQ)  : Performance governor, IRQ handling
#
# DEPENDENCIES:
#   - config.sh (CPU ranges, DEFAULT_GOVERNOR, IRQ_CPUS, ALL_CPUS)
#   - logging.sh (log_info, log_debug)
#   - checks.sh (get_usb_irqs, get_audio_irqs, get_current_state, set_state)
#   - process.sh (optimize_audio_process_affinity, reset_audio_process_affinity)
#   - usb.sh (optimize_usb_audio_settings)
#   - kernel.sh (optimize_kernel_parameters, reset_kernel_parameters,
#                optimize_advanced_audio_settings)
#
# ============================================================================
# MAIN ACTIVATION
# ============================================================================

# Activate audio optimizations - Hybrid Strategy (Stability-optimized)
activate_audio_optimizations() {
    local interface_names
    interface_names=$(get_audio_interface_names 2>/dev/null || echo "USB Audio")

    log_info "Audio interface detected ($interface_names) - Activating hybrid audio optimizations..."
    log_info "Strategy: P-Cores(0-7) Performance, Background E-Cores(8-13) Powersave, IRQ E-Cores(14-19) Performance"

    # Optimize P-Cores for audio processing (0-7)
    _optimize_p_cores

    # Keep background E-Cores on Powersave (8-13) - Reduces interference
    _configure_background_e_cores

    # IRQ E-Cores to Performance (14-19)
    _optimize_irq_e_cores

    # Defense in depth: ban RT IRQ CPUs from irqbalance (if ever started)
    _ensure_irqbalance_banned_cpus

    # Set USB controller IRQs to E-Cores
    _optimize_usb_irqs

    # Set audio IRQs to E-Cores
    _optimize_audio_irqs

    # Set audio process affinity to optimal P-Cores
    optimize_audio_process_affinity

    # USB audio interface optimizations
    optimize_usb_audio_settings

    # Kernel parameter optimizations
    optimize_kernel_parameters

    # Advanced audio optimizations
    optimize_advanced_audio_settings

    # Save state
    set_state "optimized"
    log_info "Hybrid audio optimizations activated - Stability and performance optimal!"

    # Update tray state (always write so any tray app can read it)
    if declare -f tray_write_state &> /dev/null; then
        local jack_settings
        if declare -f get_jack_compact_info &> /dev/null; then
            jack_settings=$(get_jack_compact_info 2>/dev/null || echo "unknown")
        else
            jack_settings="unknown"
        fi
        tray_write_state "optimized" "connected" "active" "$jack_settings" "0"
    fi
}

# ============================================================================
# MAIN DEACTIVATION
# ============================================================================

# Deactivate audio optimizations - Back to standard
deactivate_audio_optimizations() {
    log_info "No audio interface detected - Reset to standard configuration..."

    # Reset audio-relevant CPUs (P-Cores + IRQ E-Cores)
    _reset_cpu_governors

    # Reset process affinity
    reset_audio_process_affinity

    # Reset USB controller IRQs to all CPUs
    _reset_usb_irqs

    # Reset Audio IRQs to all CPUs
    _reset_audio_irqs

    # Reset kernel parameters
    reset_kernel_parameters

    # Save state
    set_state "standard"
    log_info "Hybrid optimizations deactivated, system reset to standard"

    # Update tray state (always write so any tray app can read it)
    if declare -f tray_write_state &> /dev/null; then
        tray_write_state "disconnected" "disconnected" "inactive" "unknown" "0"
    fi
}

# ============================================================================
# CPU GOVERNOR OPTIMIZATION
# ============================================================================

# Optimize P-Cores (0-7) for audio processing
_optimize_p_cores() {
    log_info "Optimize P-Cores (0-7) for audio processing..."

    for cpu in {0..7}; do
        # Set governor to performance
        if [ -e "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" ]; then
            if echo performance > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null; then
                log_debug "  P-Core CPU $cpu: Governor set to 'performance'"
            fi
        fi

        # P-Core specific optimizations: Set min frequency to max
        if [ -e "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" ]; then
            local max_freq
            max_freq=$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_max_freq" 2>/dev/null)
            if [ -n "$max_freq" ]; then
                if echo "$max_freq" > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" 2>/dev/null; then
                    log_debug "  P-Core CPU $cpu: Min-Frequency set to maximum"
                fi
            fi
        fi
    done
}

# Keep background E-Cores (8-13) on Powersave for stability
_configure_background_e_cores() {
    log_info "Keep Background E-Cores (8-13) on Powersave for stability..."

    for cpu in {8..13}; do
        if [ -e "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" ]; then
            local current_governor
            current_governor=$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor")
            if [ "$current_governor" != "$DEFAULT_GOVERNOR" ]; then
                if echo "$DEFAULT_GOVERNOR" > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null; then
                    log_debug "  Background E-Core CPU $cpu: Governor set to '$DEFAULT_GOVERNOR'"
                fi
            fi
        fi
    done
}

# Optimize IRQ E-Cores (14-19) for stable latency
_optimize_irq_e_cores() {
    log_info "Optimize IRQ E-Cores (14-19) for stable latency..."

    for cpu in {14..19}; do
        if [ -e "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" ]; then
            if echo performance > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null; then
                log_debug "  IRQ E-Core CPU $cpu: Governor set to 'performance'"
            fi
        fi
    done
}

# Reset CPU governors to default
_reset_cpu_governors() {
    log_info "Reset audio-relevant CPUs to standard governor..."

    # Reset P-Cores and IRQ E-Cores
    for cpu in {0..7} {14..19}; do
        if [ -e "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" ]; then
            local current_governor
            current_governor=$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor")
            if [ "$current_governor" = "performance" ]; then
                if echo "$DEFAULT_GOVERNOR" > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null; then
                    log_debug "  CPU $cpu: Governor reset to '$DEFAULT_GOVERNOR'"
                fi
            fi
        fi

        # Reset min frequency
        if [ -e "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" ]; then
            local min_freq
            min_freq=$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_min_freq" 2>/dev/null)
            if [ -n "$min_freq" ]; then
                echo "$min_freq" > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" 2>/dev/null
            fi
        fi
    done
}

# ============================================================================
# IRQ OPTIMIZATION
# ============================================================================

# Optimize USB controller IRQs
_optimize_usb_irqs() {
    local irq_cpus
    irq_cpus=$(get_effective_irq_cpus 2>/dev/null || echo "$IRQ_CPUS")
    log_info "USB controller IRQs to IRQ CPUs ($irq_cpus) for stable latency..."

    local usb_irqs
    usb_irqs=$(get_usb_irqs)

    for irq in $usb_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            if echo "$irq_cpus" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                log_debug "  USB controller IRQ $irq set to CPUs $irq_cpus"
            fi

            # IRQ optimizations: Force threading
            if [ -e "/proc/irq/$irq/threading" ]; then
                echo "forced" > "/proc/irq/$irq/threading" 2>/dev/null
            fi
        fi
    done

    # Fallback for known IRQs (common USB controller IRQs)
    for irq in 156 176; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            if echo "$irq_cpus" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                log_debug "  Fallback: IRQ $irq set to CPUs $irq_cpus"
            fi
        fi
    done
}

# Optimize audio-related IRQs
_optimize_audio_irqs() {
    local irq_cpus
    irq_cpus=$(get_effective_irq_cpus 2>/dev/null || echo "$IRQ_CPUS")
    log_info "Audio IRQs to IRQ CPUs ($irq_cpus) for optimal latency..."

    # Prefer dynamic detection via sysfs (detect_audio_irqs), fall back
    # to /proc/interrupts parsing (get_audio_irqs) for backward compatibility.
    local audio_irqs=""
    if declare -f detect_audio_irqs >/dev/null 2>&1; then
        audio_irqs=$(detect_audio_irqs)
    fi
    if [ -z "${audio_irqs// }" ]; then
        audio_irqs=$(get_audio_irqs)
    fi

    for irq in $audio_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            local current_affinity
            current_affinity=$(cat "/proc/irq/$irq/smp_affinity_list")
            if [ "$current_affinity" != "$irq_cpus" ]; then
                if echo "$irq_cpus" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                    log_debug "  Audio IRQ $irq set to CPUs $irq_cpus (was: $current_affinity)"
                fi
            fi
        fi
    done
}

# Reset USB controller IRQs to all CPUs
_reset_usb_irqs() {
    local usb_irqs
    usb_irqs=$(get_usb_irqs)

    for irq in $usb_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            if echo "$ALL_CPUS" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                log_debug "  USB controller IRQ $irq reset to all CPUs ($ALL_CPUS)"
            fi
        fi
    done
}

# Reset audio IRQs to all CPUs
_reset_audio_irqs() {
    local audio_irqs
    audio_irqs=$(get_audio_irqs)

    for irq in $audio_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            if echo "$ALL_CPUS" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                log_debug "  Audio IRQ $irq reset to all CPUs ($ALL_CPUS)"
            fi
        fi
    done
}

# ----------------------------------------------------------------------------
# irqbalance ban list (defense in depth)
# ----------------------------------------------------------------------------

# Convert "14-19" or "14,16-19" to a hex CPU mask string (e.g. "fc000").
# Returns non-zero if input yields no bits set.
_cpulist_to_hexmask() {
    local input="$1"
    local mask=0 part start end i
    for part in $(echo "$input" | tr ',' ' '); do
        if [[ "$part" == *-* ]]; then
            start="${part%-*}"
            end="${part#*-}"
            case "$start$end" in
                *[!0-9]*) continue ;;
            esac
            for ((i = start; i <= end; i++)); do
                mask=$((mask | (1 << i)))
            done
        else
            case "$part" in
                '' | *[!0-9]*) continue ;;
            esac
            mask=$((mask | (1 << part)))
        fi
    done
    [ "$mask" -eq 0 ] && return 1
    printf '%x\n' "$mask"
    return 0
}

# Write IRQBALANCE_BANNED_CPUS to /etc/default/irqbalance so that if irqbalance
# is ever (re-)enabled it will leave our RT IRQ CPUs alone. This complements
# the direct smp_affinity_list pinning — the kernel offers no userspace-writable
# per-IRQ "do not rebalance" flag on mainline, so this is the best defense.
_ensure_irqbalance_banned_cpus() {
    local config_file="/etc/default/irqbalance"

    local irq_cpus
    irq_cpus=$(get_effective_irq_cpus 2>/dev/null || echo "$IRQ_CPUS")
    [ -z "$irq_cpus" ] && return 0

    local mask
    mask=$(_cpulist_to_hexmask "$irq_cpus") || return 0

    local new_line="IRQBALANCE_BANNED_CPUS=\"$mask\""

    if [ ! -f "$config_file" ]; then
        echo "$new_line" > "$config_file" 2>/dev/null || return 0
        log_info "  Created $config_file with IRQBALANCE_BANNED_CPUS=$mask"
        return 0
    fi

    local current
    current=$(grep -E "^IRQBALANCE_BANNED_CPUS=" "$config_file" 2>/dev/null \
              | tail -n1 | cut -d= -f2- | tr -d '"')

    if [ "$current" = "$mask" ]; then
        return 0
    fi

    if grep -qE "^IRQBALANCE_BANNED_CPUS=" "$config_file"; then
        sed -i -E "s|^IRQBALANCE_BANNED_CPUS=.*|$new_line|" "$config_file" 2>/dev/null \
            && log_info "  Updated IRQBALANCE_BANNED_CPUS=$mask in $config_file (was: ${current:-unset})"
    else
        echo "$new_line" >> "$config_file" 2>/dev/null \
            && log_info "  Added IRQBALANCE_BANNED_CPUS=$mask to $config_file"
    fi
}

# ============================================================================
# OPTIMIZATION STATUS HELPERS
# ============================================================================

# Count optimized USB IRQs
count_optimized_usb_irqs() {
    local optimized=0
    local total=0
    local usb_irqs
    local irq_cpus
    irq_cpus=$(get_effective_irq_cpus 2>/dev/null || echo "$IRQ_CPUS")

    usb_irqs=$(get_usb_irqs)

    for irq in $usb_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            total=$((total + 1))
            local affinity
            affinity=$(cat "/proc/irq/$irq/smp_affinity_list")
            if [ "$affinity" = "$irq_cpus" ]; then
                optimized=$((optimized + 1))
            fi
        fi
    done

    echo "$optimized/$total"
}

# Count optimized audio IRQs
count_optimized_audio_irqs() {
    local optimized=0
    local total=0
    local audio_irqs
    local irq_cpus
    irq_cpus=$(get_effective_irq_cpus 2>/dev/null || echo "$IRQ_CPUS")

    audio_irqs=$(get_audio_irqs)

    for irq in $audio_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            total=$((total + 1))
            local affinity
            affinity=$(cat "/proc/irq/$irq/smp_affinity_list")
            if [ "$affinity" = "$irq_cpus" ]; then
                optimized=$((optimized + 1))
            fi
        fi
    done

    echo "$optimized/$total"
}

# Check if system is currently optimized
is_system_optimized() {
    local current_state
    current_state=$(get_current_state)

    if [ "$current_state" = "optimized" ]; then
        return 0
    else
        return 1
    fi
}
