#!/bin/bash

# Realtime Audio Optimizer - Kernel Module
# Handles kernel parameter optimization for audio performance
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   optimize_kernel_parameters()
#     Applies audio-optimized kernel parameter settings.
#     @return   : void
#     @requires : Root privileges
#     @modifies : /proc/sys/kernel/sched_rt_runtime_us -> -1
#                 /proc/sys/vm/swappiness -> 10
#                 /proc/sys/kernel/sched_latency_ns -> 1000000
#                 /proc/sys/kernel/sched_min_granularity_ns -> 100000
#                 /proc/sys/kernel/sched_wakeup_granularity_ns -> 100000
#
#   reset_kernel_parameters()
#     Reverts kernel parameters to Ubuntu/desktop defaults.
#     @return   : void
#     @requires : Root privileges
#     @modifies : Restores default values for all parameters above
#
#   optimize_advanced_audio_settings()
#     Applies supplementary audio optimizations.
#     @return   : void
#     @requires : Root privileges
#     @modifies : /sys/module/usbcore/parameters/usbfs_memory_mb -> 256
#                 /proc/sys/dev/hpet/max-user-freq -> 2048
#                 /sys/class/net/*/queues/rx-*/rps_cpus -> 0x3f00
#
#   get_rt_runtime()
#     Gets current RT scheduling limit.
#     @return : string - Value in microseconds, "-1", or "N/A"
#     @stdout : RT runtime limit
#
#   get_swappiness()
#     Gets current swappiness setting.
#     @return : string - Value 0-100 or "N/A"
#     @stdout : Swappiness value
#
#   get_sched_latency()
#     Gets current scheduler latency.
#     @return : string - Value in nanoseconds or "N/A"
#     @stdout : Scheduler latency
#
#   get_min_granularity()
#     Gets current minimum granularity.
#     @return : string - Value in nanoseconds or "N/A"
#     @stdout : Min granularity
#
#   get_dirty_ratio()
#     Gets current dirty page ratio.
#     @return : string - Value 0-100 or "N/A"
#     @stdout : Dirty ratio percentage
#
#   get_rt_period()
#     Gets current RT scheduling period.
#     @return : string - Value in microseconds or "N/A"
#     @stdout : RT period
#
#   show_kernel_status()
#     Displays kernel parameter status.
#     @return : void
#     @stdout : Formatted status output
#
#   show_advanced_kernel_status()
#     Displays detailed kernel parameter status.
#     @return : void
#     @stdout : Extended formatted status output
#
# PRIVATE FUNCTIONS:
#
#   _optimize_network_rps()
#     Redirects network RPS to background E-Cores.
#     @return   : void
#     @modifies : /sys/class/net/*/queues/rx-*/rps_cpus
#
# KERNEL PARAMETERS (Audio-Optimized -> Default):
#
#   sched_rt_runtime_us:      -1 (unlimited) -> 950000 (95%)
#   swappiness:               10 -> 60
#   sched_latency_ns:         1000000 (1ms) -> 6000000 (6ms)
#   sched_min_granularity_ns: 100000 (0.1ms) -> 750000 (0.75ms)
#   sched_wakeup_granularity_ns: 100000 (0.1ms) -> 1000000 (1ms)
#   usbfs_memory_mb:          256 -> 16
#   hpet/max-user-freq:       2048 -> 64
#
# DEPENDENCIES:
#   - logging.sh (log_info, log_debug)
#
# ============================================================================
# KERNEL PARAMETER OPTIMIZATION
# ============================================================================
#
# Kernel parameters affect how the Linux scheduler handles processes.
# For audio, we want:
#   - Unlimited RT scheduling time (no throttling of RT tasks)
#   - Reduced swapping (memory should stay in RAM)
#   - Finer scheduler granularity (faster context switches)
#
# These settings trade overall system responsiveness for audio priority.

# Optimize kernel parameters for audio processing
# Applies all audio-optimized kernel parameter settings.
# Requires root privileges.
optimize_kernel_parameters() {
    log_info "Optimize kernel parameters for audio..."

    # Real-Time Scheduling - Allow unlimited RT scheduling
    # Default: 950000 (95% of period). -1 = no limit on RT task CPU time
    # Warning: Poorly written RT tasks could hang the system with -1
    if [ -e /proc/sys/kernel/sched_rt_runtime_us ]; then
        if echo -1 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null; then
            log_debug "  RT-Runtime: Unlimited"
        fi
    fi

    # Memory Management - Reduce swapping for audio stability
    # Default: 60. Lower values = less swapping, more RAM pressure
    # 10 = only swap when absolutely necessary
    if [ -e /proc/sys/vm/swappiness ]; then
        if echo 10 > /proc/sys/vm/swappiness 2>/dev/null; then
            log_debug "  Swappiness: 10"
        fi
    fi

    # Scheduler Latency - Target latency for CPU-bound tasks
    # Default: 6ms. Lower = more frequent scheduling, better latency
    # 1ms is aggressive but good for audio
    if [ -e /proc/sys/kernel/sched_latency_ns ]; then
        if echo 1000000 > /proc/sys/kernel/sched_latency_ns 2>/dev/null; then
            log_debug "  Scheduler latency: 1ms"
        fi
    fi

    # Minimum Granularity - Minimum time slice for tasks
    # Default: 0.75ms. Lower = more preemption opportunities
    # 0.1ms allows very fine-grained scheduling
    if [ -e /proc/sys/kernel/sched_min_granularity_ns ]; then
        if echo 100000 > /proc/sys/kernel/sched_min_granularity_ns 2>/dev/null; then
            log_debug "  Min granularity: 0.1ms"
        fi
    fi

    # Wakeup Granularity - How quickly a waking task can preempt
    # Default: 1ms. Lower = faster response to events
    # 0.1ms ensures audio callbacks get CPU quickly
    if [ -e /proc/sys/kernel/sched_wakeup_granularity_ns ]; then
        if echo 100000 > /proc/sys/kernel/sched_wakeup_granularity_ns 2>/dev/null; then
            log_debug "  Wakeup granularity: 0.1ms"
        fi
    fi
}

# ============================================================================
# KERNEL PARAMETER RESET
# ============================================================================
#
# Restores kernel parameters to Ubuntu/desktop-friendly defaults.
# These values balance responsiveness with power efficiency.

# Reset kernel parameters to standard values
# Reverts all audio optimizations to system defaults.
# Requires root privileges.
reset_kernel_parameters() {
    log_info "Reset kernel parameters..."

    # RT-Scheduling-Limit: Standard (95% of period for RT tasks)
    if [ -e /proc/sys/kernel/sched_rt_runtime_us ]; then
        if echo 950000 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null; then
            log_debug "  RT-Runtime: Standard (950ms)"
        fi
    fi

    # Swappiness: Standard
    if [ -e /proc/sys/vm/swappiness ]; then
        if echo 60 > /proc/sys/vm/swappiness 2>/dev/null; then
            log_debug "  Swappiness: Standard (60)"
        fi
    fi

    # Scheduler latency: Standard
    if [ -e /proc/sys/kernel/sched_latency_ns ]; then
        if echo 6000000 > /proc/sys/kernel/sched_latency_ns 2>/dev/null; then
            log_debug "  Scheduler latency: Standard (6ms)"
        fi
    fi

    # Min granularity: Standard
    if [ -e /proc/sys/kernel/sched_min_granularity_ns ]; then
        if echo 750000 > /proc/sys/kernel/sched_min_granularity_ns 2>/dev/null; then
            log_debug "  Min granularity: Standard (0.75ms)"
        fi
    fi

    # Wakeup granularity: Standard
    if [ -e /proc/sys/kernel/sched_wakeup_granularity_ns ]; then
        if echo 1000000 > /proc/sys/kernel/sched_wakeup_granularity_ns 2>/dev/null; then
            log_debug "  Wakeup granularity: Standard (1ms)"
        fi
    fi
}

# ============================================================================
# ADVANCED AUDIO OPTIMIZATIONS
# ============================================================================
#
# Additional optimizations beyond basic kernel parameters:
#   - USB memory buffer: Larger buffers for USB audio stability
#   - HPET frequency: Higher precision timing for audio callbacks
#   - Network RPS: Keep network interrupts off audio CPUs

# Activate advanced audio optimizations
# Applies supplementary optimizations for better audio performance.
# Requires root privileges.
optimize_advanced_audio_settings() {
    log_info "Activating advanced audio optimizations..."

    # USB-Bulk-Transfer-Optimizations - Increase USB buffer
    # Default: 16MB. 256MB provides headroom for high-bandwidth USB audio
    if [ -e /sys/module/usbcore/parameters/usbfs_memory_mb ]; then
        if echo 256 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null; then
            log_debug "  USB-Memory-Buffer: 256MB"
        fi
    fi

    # HPET frequency - Increase for better timing precision
    # HPET (High Precision Event Timer) is used for accurate audio timing
    # Default: 64Hz. 2048Hz allows more precise scheduling
    if [ -e /proc/sys/dev/hpet/max-user-freq ]; then
        if echo 2048 > /proc/sys/dev/hpet/max-user-freq 2>/dev/null; then
            log_debug "  HPET-Frequency: 2048Hz"
        fi
    fi

    # Redirect network interface interrupts away from audio CPUs
    _optimize_network_rps
}

# Optimize network RPS (Receive Packet Steering) to avoid audio CPU interference
# RPS distributes network packet processing across CPUs. By restricting it
# to background E-Cores, we prevent network activity from interrupting
# audio processing on P-Cores.
#
# The bitmask 0x3f00 = binary 0011 1111 0000 0000 = CPUs 8-13
_optimize_network_rps() {
    for netif in /sys/class/net/*/queues/rx-*/rps_cpus; do
        if [ -e "$netif" ]; then
            # Restrict network RPS to E-Cores 8-13 (binary: 0011 1111 0000 0000 = 0x3f00)
            echo "00003f00" > "$netif" 2>/dev/null
        fi
    done
    log_debug "  Network-Interrupts redirected to Background-E-Cores"
}

# ============================================================================
# KERNEL PARAMETER QUERIES
# ============================================================================
#
# Query functions for reading current kernel parameter values.
# Used by status display functions.

# Get current RT runtime setting
# Returns: RT runtime limit in microseconds, -1 for unlimited, or "N/A"
get_rt_runtime() {
    if [ -e /proc/sys/kernel/sched_rt_runtime_us ]; then
        cat /proc/sys/kernel/sched_rt_runtime_us
    else
        echo "N/A"
    fi
}

# Get current swappiness setting
get_swappiness() {
    if [ -e /proc/sys/vm/swappiness ]; then
        cat /proc/sys/vm/swappiness
    else
        echo "N/A"
    fi
}

# Get current scheduler latency setting
get_sched_latency() {
    if [ -e /proc/sys/kernel/sched_latency_ns ]; then
        cat /proc/sys/kernel/sched_latency_ns
    else
        echo "N/A"
    fi
}

# Get current min granularity setting
get_min_granularity() {
    if [ -e /proc/sys/kernel/sched_min_granularity_ns ]; then
        cat /proc/sys/kernel/sched_min_granularity_ns
    else
        echo "N/A"
    fi
}

# Get current dirty ratio setting
get_dirty_ratio() {
    if [ -e /proc/sys/vm/dirty_ratio ]; then
        cat /proc/sys/vm/dirty_ratio
    else
        echo "N/A"
    fi
}

# Get current RT period setting
get_rt_period() {
    if [ -e /proc/sys/kernel/sched_rt_period_us ]; then
        cat /proc/sys/kernel/sched_rt_period_us
    else
        echo "N/A"
    fi
}

# ============================================================================
# STATUS DISPLAY HELPERS
# ============================================================================
#
# Functions to display kernel parameter status for user information.

# Display kernel parameter status
# Shows current values of audio-relevant kernel parameters.
# Output: Prints status to stdout
show_kernel_status() {
    local rt_runtime
    rt_runtime=$(get_rt_runtime)

    echo "Kernel parameter status:"

    # RT Runtime
    if [ "$rt_runtime" = "-1" ]; then
        echo "   RT-Scheduling-Limit: Unlimited"
    elif [ "$rt_runtime" != "N/A" ]; then
        echo "   RT-Scheduling-Limit: $rt_runtime us"
    fi

    # RT Period
    local rt_period
    rt_period=$(get_rt_period)
    if [ "$rt_period" != "N/A" ]; then
        echo "   RT-Period: $rt_period us"
    fi

    # Swappiness
    local swappiness
    swappiness=$(get_swappiness)
    if [ "$swappiness" != "N/A" ]; then
        echo "   Swappiness: $swappiness"
    fi

    # Dirty ratio
    local dirty_ratio
    dirty_ratio=$(get_dirty_ratio)
    if [ "$dirty_ratio" != "N/A" ]; then
        echo "   Dirty Ratio: $dirty_ratio%"
    fi
}

# Display advanced kernel parameter status (for detailed view)
show_advanced_kernel_status() {
    echo "   RT-Scheduling:"

    local rt_runtime
    rt_runtime=$(get_rt_runtime)
    if [ "$rt_runtime" = "-1" ]; then
        echo "     RT-Runtime: Unlimited"
    elif [ "$rt_runtime" != "N/A" ]; then
        echo "     RT-Runtime: $rt_runtime us"
    fi

    local rt_period
    rt_period=$(get_rt_period)
    if [ "$rt_period" != "N/A" ]; then
        echo "     RT-Period: $rt_period us"
    fi

    echo "   Memory Management:"

    local swappiness
    swappiness=$(get_swappiness)
    if [ "$swappiness" != "N/A" ]; then
        echo "     Swappiness: $swappiness"
    fi

    local dirty_ratio
    dirty_ratio=$(get_dirty_ratio)
    if [ "$dirty_ratio" != "N/A" ]; then
        echo "     Dirty Ratio: $dirty_ratio%"
    fi
}
