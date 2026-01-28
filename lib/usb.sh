#!/bin/bash

# Realtime Audio Optimizer - USB Module
# Contains USB audio interface optimization functions
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   optimize_usb_audio_settings()
#     Main entry point for USB optimizations.
#     @return : void
#     @exit   : 0 on success, 1 if no devices found
#     @sysfs  : Modifies USB device power and transfer settings
#     @requires : Root privileges
#
#   get_usb_audio_power_status()
#     Gets formatted USB power and connection status for all interfaces.
#     @return : void
#     @exit   : 0 if found, 1 if not found
#     @stdout : Multi-line status information
#
#   get_usb_audio_details()
#     Gets lsusb details for all detected audio interfaces.
#     @return : void
#     @stdout : USB bus and device information
#
#   optimize_usb_memory()
#     Increases global USB filesystem memory buffer.
#     @return : void
#     @exit   : 0 on success, 1 on failure
#     @sysfs  : Modifies /sys/module/usbcore/parameters/usbfs_memory_mb
#     @requires : Root privileges
#
#   get_usb_memory_setting()
#     Gets current usbfs memory buffer size.
#     @return : string - Size in MB or "N/A"
#     @stdout : Memory size
#
# PRIVATE FUNCTIONS (internal use only):
#
#   _optimize_usb_power(usb_device)
#     Disables USB power management for device.
#     @param  usb_device : string - Sysfs device path
#     @return            : void
#     @sysfs             : Modifies power/control, power/autosuspend*
#
#   _optimize_usb_transfer(usb_device)
#     Optimizes USB transfer settings (URB count).
#     @param  usb_device : string - Sysfs device path
#     @return            : void
#     @sysfs             : Modifies urbnum if available
#
# DEPENDENCIES:
#   - interfaces.sh (get_audio_interface_usb_paths, get_audio_interface_names)
#   - logging.sh (log_info, log_debug, log_warn)
#
# ============================================================================
# USB AUDIO OPTIMIZATION
# ============================================================================
#
# USB optimization is critical for audio interfaces to prevent dropouts.
# Key optimizations:
#   - Disable USB autosuspend to keep device always active
#   - Increase USB buffer memory for better throughput
#   - Optimize URB (USB Request Block) count for smoother transfers

# Optimize USB settings for all detected audio interfaces
# Main entry point for USB optimizations. Finds all devices and applies
# all USB-related optimizations to each.
#
# Returns: 0 on success, 1 if no devices found
optimize_usb_audio_settings() {
    log_info "Optimizing USB audio interface settings..."

    local usb_paths
    usb_paths=$(get_audio_interface_usb_paths)

    if [ -z "$usb_paths" ]; then
        log_warn "  No USB audio interfaces found"
        return 1
    fi

    local count=0
    while IFS= read -r usb_device_path; do
        [ -z "$usb_device_path" ] && continue
        [ ! -d "$usb_device_path" ] && continue

        log_debug "  Optimizing USB device: $usb_device_path"

        # Disable power management for this device
        _optimize_usb_power "$usb_device_path"

        # Optimize USB bulk transfer settings
        _optimize_usb_transfer "$usb_device_path"

        count=$((count + 1))
    done <<< "$usb_paths"

    log_info "  Optimized $count USB audio interface(s)"
    return 0
}

# Legacy compatibility: optimize_motu_usb_settings now calls optimize_usb_audio_settings
optimize_motu_usb_settings() {
    optimize_usb_audio_settings
}

# ============================================================================
# USB POWER MANAGEMENT
# ============================================================================
#
# USB power management can cause audio dropouts when the device enters
# suspend mode. These settings ensure audio interfaces stay fully powered.

# Optimize USB power management for audio device
# Disables all power saving features that could cause audio interruptions.
#
# Args:
#   $1 - USB device sysfs path
#
# Modifies:
#   - power/control: Set to "on" (disable runtime PM)
#   - power/autosuspend: Set to -1 (disable autosuspend)
#   - power/autosuspend_delay_ms: Set to -1 (disable delay-based suspend)
_optimize_usb_power() {
    local usb_device="$1"

    # Disable USB autosuspend - keep device always on
    # "on" means device is always active, "auto" allows power management
    if [ -e "$usb_device/power/control" ]; then
        if echo "on" > "$usb_device/power/control" 2>/dev/null; then
            log_debug "    Power-Management: always on"
        fi
    fi

    # Disable autosuspend delay (legacy interface)
    # -1 = never autosuspend
    if [ -e "$usb_device/power/autosuspend" ]; then
        if echo -1 > "$usb_device/power/autosuspend" 2>/dev/null; then
            log_debug "    Autosuspend: disabled"
        fi
    fi

    # Disable autosuspend delay (ms version - newer kernels)
    # -1 = never autosuspend
    if [ -e "$usb_device/power/autosuspend_delay_ms" ]; then
        if echo -1 > "$usb_device/power/autosuspend_delay_ms" 2>/dev/null; then
            log_debug "    Autosuspend-Delay: disabled"
        fi
    fi

    # Log runtime PM status for debugging
    if [ -e "$usb_device/power/runtime_status" ]; then
        local runtime_status
        runtime_status=$(cat "$usb_device/power/runtime_status" 2>/dev/null)
        log_debug "    Runtime status: $runtime_status"
    fi
}

# ============================================================================
# USB TRANSFER OPTIMIZATION
# ============================================================================
#
# URBs (USB Request Blocks) are the data structures used for USB transfers.
# More URBs = more buffering = smoother audio at the cost of slightly higher latency.

# Optimize USB transfer settings
# Increases URB count for better audio streaming stability.
#
# Args:
#   $1 - USB device sysfs path
#
# Note: The urbnum parameter may not be writable on all systems/kernels.
#       This is normal and the optimization will be skipped silently.
_optimize_usb_transfer() {
    local usb_device="$1"

    # Increase URB count for better buffer handling
    # Default is typically 2-4, increasing to 32 provides more buffering
    # Note: urbnum is read-only on most systems, so this is best-effort
    if [ -e "$usb_device/urbnum" ]; then
        { echo 32 > "$usb_device/urbnum"; } 2>/dev/null && \
            log_debug "    URB count increased to 32"
    fi
}

# ============================================================================
# USB STATUS INFORMATION
# ============================================================================

# Get USB power status for all detected audio interfaces
# Returns formatted status information
get_usb_audio_power_status() {
    local usb_paths
    usb_paths=$(get_audio_interface_usb_paths)

    if [ -z "$usb_paths" ]; then
        echo "   No USB audio interfaces found"
        return 1
    fi

    while IFS= read -r usb_device; do
        [ -z "$usb_device" ] && continue
        [ ! -d "$usb_device" ] && continue

        echo "   USB-Device: $usb_device"

        # Get device name if available
        if [ -f "$usb_device/product" ]; then
            local product
            product=$(cat "$usb_device/product" 2>/dev/null)
            echo "   Product: $product"
        fi

        if [ -e "$usb_device/power/control" ]; then
            local control
            control=$(cat "$usb_device/power/control" 2>/dev/null)
            echo "   Power Control: $control"
        fi

        if [ -e "$usb_device/power/autosuspend_delay_ms" ]; then
            local delay
            delay=$(cat "$usb_device/power/autosuspend_delay_ms" 2>/dev/null)
            echo "   Autosuspend Delay: $delay ms"
        fi

        if [ -e "$usb_device/speed" ]; then
            local speed
            speed=$(cat "$usb_device/speed" 2>/dev/null)
            echo "   USB Speed: $speed"
        fi

        if [ -e "$usb_device/version" ]; then
            local version
            version=$(cat "$usb_device/version" 2>/dev/null | tr -d ' ')
            echo "   USB Version: $version"
        fi

        if [ -e "$usb_device/bMaxPower" ]; then
            local max_power
            max_power=$(cat "$usb_device/bMaxPower" 2>/dev/null)
            echo "   Max Power: $max_power"
        fi

        echo ""
    done <<< "$usb_paths"
}

# Legacy compatibility
get_motu_usb_power_status() {
    get_usb_audio_power_status
}

# Get detailed USB connection info for all audio interfaces
get_usb_audio_details() {
    local interface_names
    interface_names=$(get_audio_interface_names)

    if [ -n "$interface_names" ]; then
        echo "   Detected interfaces: $interface_names"

        # Show lsusb info for each detected interface
        local usb_paths
        usb_paths=$(get_audio_interface_usb_paths)

        while IFS= read -r usb_device; do
            [ -z "$usb_device" ] && continue
            [ ! -d "$usb_device" ] && continue

            if [ -f "$usb_device/idVendor" ] && [ -f "$usb_device/idProduct" ]; then
                local vendor product
                vendor=$(cat "$usb_device/idVendor" 2>/dev/null)
                product=$(cat "$usb_device/idProduct" 2>/dev/null)

                local lsusb_info
                lsusb_info=$(lsusb -d "$vendor:$product" 2>/dev/null | head -1)
                [ -n "$lsusb_info" ] && echo "   $lsusb_info"
            fi
        done <<< "$usb_paths"
    else
        echo "   No USB audio interfaces found"
    fi
}

# Legacy compatibility
get_motu_usb_details() {
    get_usb_audio_details
}

# ============================================================================
# USB MEMORY OPTIMIZATION
# ============================================================================
#
# The usbfs memory buffer limits how much data can be in-flight for USB
# transfers. The default (16MB) can be too low for high-bandwidth audio
# interfaces, especially at high sample rates.

# Optimize USB subsystem memory settings
# Increases the global USB filesystem memory buffer to 256MB.
# This affects all USB devices, not just audio interfaces.
#
# Returns: 0 on success, 1 on failure
#
# Note: Requires root privileges to modify
optimize_usb_memory() {
    # Increase USB filesystem memory buffer
    # Default is typically 16MB, 256MB provides headroom for high-bandwidth audio
    if [ -e /sys/module/usbcore/parameters/usbfs_memory_mb ]; then
        if echo 256 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null; then
            log_debug "  USB-Memory-Buffer: 256MB"
            return 0
        fi
    fi
    return 1
}

# Get current USB memory setting
# Returns the current usbfs memory buffer size in MB.
#
# Returns: Memory size in MB, or "N/A" if unavailable
get_usb_memory_setting() {
    if [ -e /sys/module/usbcore/parameters/usbfs_memory_mb ]; then
        cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null
    else
        echo "N/A"
    fi
}
