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
    log_info "USB controller IRQs to E-Cores (14-19) for stable latency..."

    local usb_irqs
    usb_irqs=$(get_usb_irqs)

    for irq in $usb_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            if echo "$IRQ_CPUS" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                log_debug "  USB controller IRQ $irq set to E-Cores $IRQ_CPUS"
            fi

            # IRQ optimizations: Force threading
            if [ -e "/proc/irq/$irq/threading" ]; then
                echo "forced" > "/proc/irq/$irq/threading" 2>/dev/null
            fi

            # Disable IRQ balancing for this IRQ
            if [ -e "/proc/irq/$irq/balance_disabled" ]; then
                echo 1 > "/proc/irq/$irq/balance_disabled" 2>/dev/null
            fi
        fi
    done

    # Fallback for known IRQs (common USB controller IRQs)
    for irq in 156 176; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            if echo "$IRQ_CPUS" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                log_debug "  Fallback: IRQ $irq set to E-Cores $IRQ_CPUS"
            fi
        fi
    done
}

# Optimize audio-related IRQs
_optimize_audio_irqs() {
    log_info "Audio IRQs to E-Cores (14-19) for optimal latency..."

    local audio_irqs
    audio_irqs=$(get_audio_irqs)

    for irq in $audio_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            local current_affinity
            current_affinity=$(cat "/proc/irq/$irq/smp_affinity_list")
            if [ "$current_affinity" != "$IRQ_CPUS" ]; then
                if echo "$IRQ_CPUS" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                    log_debug "  Audio IRQ $irq set to E-Cores $IRQ_CPUS (was: $current_affinity)"
                fi
            fi

            # Disable IRQ balance for audio IRQs
            if [ -e "/proc/irq/$irq/balance_disabled" ]; then
                echo 1 > "/proc/irq/$irq/balance_disabled" 2>/dev/null
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

            # Re-enable IRQ balancing
            if [ -e "/proc/irq/$irq/balance_disabled" ]; then
                echo 0 > "/proc/irq/$irq/balance_disabled" 2>/dev/null
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

            # Re-enable IRQ balancing
            if [ -e "/proc/irq/$irq/balance_disabled" ]; then
                echo 0 > "/proc/irq/$irq/balance_disabled" 2>/dev/null
            fi
        fi
    done
}

# ============================================================================
# OPTIMIZATION STATUS HELPERS
# ============================================================================

# Count optimized USB IRQs
count_optimized_usb_irqs() {
    local optimized=0
    local total=0
    local usb_irqs

    usb_irqs=$(get_usb_irqs)

    for irq in $usb_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            total=$((total + 1))
            local affinity
            affinity=$(cat "/proc/irq/$irq/smp_affinity_list")
            if [ "$affinity" = "$IRQ_CPUS" ]; then
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

    audio_irqs=$(get_audio_irqs)

    for irq in $audio_irqs; do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
            total=$((total + 1))
            local affinity
            affinity=$(cat "/proc/irq/$irq/smp_affinity_list")
            if [ "$affinity" = "$IRQ_CPUS" ]; then
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
