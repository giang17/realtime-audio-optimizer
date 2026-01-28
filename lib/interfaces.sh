#!/bin/bash

# Realtime Audio Optimizer - Audio Interface Detection Module
# Provides functions for detecting USB audio interfaces
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   detect_usb_audio_interfaces()
#     Detects all connected USB audio interfaces.
#     @return : string - Newline-separated list of interface info
#     @stdout : List of detected interfaces (format: "card_name|alsa_id|usb_path|vendor:product")
#
#   get_audio_interface_count()
#     Returns the number of detected USB audio interfaces.
#     @return : int - Number of interfaces
#
#   get_audio_interface_names()
#     Returns human-readable names of detected interfaces.
#     @return : string - Comma-separated list of names
#
#   get_audio_interface_usb_paths()
#     Returns sysfs USB paths for all detected audio interfaces.
#     @return : string - Newline-separated list of paths
#
#   is_audio_interface_connected()
#     Checks if at least one USB audio interface is connected.
#     @exit   : 0 if connected, 1 if not
#
#   get_primary_audio_interface()
#     Gets info about the primary (first detected) interface.
#     @return : string - Interface info string
#
# DEPENDENCIES:
#   - logging.sh (log_debug, log_info)
#
# ============================================================================
# USB AUDIO CLASS DETECTION
# ============================================================================
#
# USB Audio Class (UAC) devices are identified by:
#   - bInterfaceClass = 01 (Audio)
#   - Presence in /proc/asound/ as USB-Audio device
#
# This module provides device-agnostic detection that works with any
# USB audio interface including MOTU, Focusrite, Behringer, etc.

# Array to store detected interfaces (populated by detect_usb_audio_interfaces)
declare -a DETECTED_INTERFACES=()

# Detect all USB audio interfaces
# Uses multiple detection methods for reliability:
#   1. ALSA USB-Audio card detection
#   2. Sysfs USB Audio Class detection
#
# Populates DETECTED_INTERFACES array and returns interface list.
# Each entry format: "card_name|alsa_id|usb_path|vendor:product|friendly_name"
detect_usb_audio_interfaces() {
    DETECTED_INTERFACES=()
    local interfaces=()

    # Method 1: Check ALSA cards for USB-Audio devices
    for card_dir in /proc/asound/card*; do
        [ -d "$card_dir" ] || continue

        local card_name=""
        local card_id=""
        local usb_path=""
        local vendor_product=""
        local friendly_name=""

        # Get card ID (e.g., "M4", "Scarlett", etc.)
        if [ -f "$card_dir/id" ]; then
            card_id=$(cat "$card_dir/id" 2>/dev/null)
        fi

        # Check if this is a USB audio device
        local is_usb_audio=false

        # Check usbid file (present for USB audio devices)
        if [ -f "$card_dir/usbid" ]; then
            is_usb_audio=true
            vendor_product=$(cat "$card_dir/usbid" 2>/dev/null)
        fi

        # Alternative: check usbbus file
        if [ -f "$card_dir/usbbus" ]; then
            is_usb_audio=true
        fi

        # Alternative: check stream0 for USB-Audio signature
        if [ -f "$card_dir/stream0" ] && grep -q "USB Audio" "$card_dir/stream0" 2>/dev/null; then
            is_usb_audio=true
        fi

        if $is_usb_audio && [ -n "$card_id" ]; then
            card_name=$(basename "$card_dir")

            # Try to find USB sysfs path
            usb_path=$(_find_usb_path_for_card "$card_name" "$vendor_product")

            # Get friendly name from ALSA
            if [ -f "$card_dir/id" ]; then
                # Try to get longer name from stream0 or codec info
                if [ -f "$card_dir/stream0" ]; then
                    friendly_name=$(head -1 "$card_dir/stream0" 2>/dev/null | sed 's/ at usb.*//')
                fi
            fi
            [ -z "$friendly_name" ] && friendly_name="$card_id"

            local entry="${card_name}|${card_id}|${usb_path}|${vendor_product}|${friendly_name}"
            interfaces+=("$entry")
            log_debug "  Detected USB audio: $friendly_name ($card_id) at $usb_path"
        fi
    done

    # Method 2: Scan sysfs for USB Audio Class devices not yet in ALSA
    # (catches devices that are connected but not fully initialized)
    for usb_dev in /sys/bus/usb/devices/*/bInterfaceClass; do
        [ -f "$usb_dev" ] || continue

        local iface_class=$(cat "$usb_dev" 2>/dev/null)
        # bInterfaceClass = 01 is Audio
        if [ "$iface_class" = "01" ]; then
            local usb_path="${usb_dev%/bInterfaceClass}"
            usb_path="${usb_path%/*}"  # Go up to device level

            # Skip if already detected via ALSA
            local already_found=false
            for entry in "${interfaces[@]}"; do
                if [[ "$entry" == *"$usb_path"* ]]; then
                    already_found=true
                    break
                fi
            done

            if ! $already_found && [ -f "$usb_path/idVendor" ]; then
                local vendor=$(cat "$usb_path/idVendor" 2>/dev/null)
                local product=$(cat "$usb_path/idProduct" 2>/dev/null)
                local vendor_product="${vendor}:${product}"

                # Get product name if available
                local friendly_name="USB Audio Device"
                if [ -f "$usb_path/product" ]; then
                    friendly_name=$(cat "$usb_path/product" 2>/dev/null)
                fi

                local entry="pending||${usb_path}|${vendor_product}|${friendly_name}"
                interfaces+=("$entry")
                log_debug "  Detected USB audio (not yet in ALSA): $friendly_name at $usb_path"
            fi
        fi
    done

    DETECTED_INTERFACES=("${interfaces[@]}")

    # Output the list
    for entry in "${interfaces[@]}"; do
        echo "$entry"
    done
}

# Internal: Find USB sysfs path for an ALSA card
_find_usb_path_for_card() {
    local card_name="$1"
    local vendor_product="$2"

    # If we have vendor:product, search by that
    if [ -n "$vendor_product" ]; then
        local vendor="${vendor_product%%:*}"
        local product="${vendor_product##*:}"

        for usb_dev in /sys/bus/usb/devices/*; do
            [ -d "$usb_dev" ] || continue
            [ -f "$usb_dev/idVendor" ] || continue

            local dev_vendor=$(cat "$usb_dev/idVendor" 2>/dev/null)
            local dev_product=$(cat "$usb_dev/idProduct" 2>/dev/null)

            if [ "$dev_vendor" = "$vendor" ] && [ "$dev_product" = "$product" ]; then
                echo "$usb_dev"
                return 0
            fi
        done
    fi

    # Fallback: try to find via sound device symlink
    local card_num="${card_name#card}"
    if [ -L "/sys/class/sound/$card_name" ]; then
        local sound_path=$(readlink -f "/sys/class/sound/$card_name")
        # Walk up to find USB device
        local current="$sound_path"
        while [ -n "$current" ] && [ "$current" != "/" ]; do
            if [ -f "$current/idVendor" ]; then
                echo "$current"
                return 0
            fi
            current=$(dirname "$current")
        done
    fi

    echo ""
    return 1
}

# Get number of detected audio interfaces
get_audio_interface_count() {
    if [ ${#DETECTED_INTERFACES[@]} -eq 0 ]; then
        detect_usb_audio_interfaces > /dev/null
    fi
    echo "${#DETECTED_INTERFACES[@]}"
}

# Get comma-separated list of interface names
get_audio_interface_names() {
    if [ ${#DETECTED_INTERFACES[@]} -eq 0 ]; then
        detect_usb_audio_interfaces > /dev/null
    fi

    local names=""
    for entry in "${DETECTED_INTERFACES[@]}"; do
        local name="${entry##*|}"  # Last field is friendly name
        [ -n "$names" ] && names="$names, "
        names="$names$name"
    done
    echo "$names"
}

# Get all USB sysfs paths for detected interfaces
get_audio_interface_usb_paths() {
    if [ ${#DETECTED_INTERFACES[@]} -eq 0 ]; then
        detect_usb_audio_interfaces > /dev/null
    fi

    for entry in "${DETECTED_INTERFACES[@]}"; do
        # Format: card_name|alsa_id|usb_path|vendor:product|friendly_name
        local usb_path=$(echo "$entry" | cut -d'|' -f3)
        [ -n "$usb_path" ] && echo "$usb_path"
    done
}

# Check if any audio interface is connected
is_audio_interface_connected() {
    local count=$(get_audio_interface_count)
    [ "$count" -gt 0 ]
}

# Get primary (first) audio interface info
get_primary_audio_interface() {
    if [ ${#DETECTED_INTERFACES[@]} -eq 0 ]; then
        detect_usb_audio_interfaces > /dev/null
    fi

    if [ ${#DETECTED_INTERFACES[@]} -gt 0 ]; then
        echo "${DETECTED_INTERFACES[0]}"
    fi
}

# Get ALSA card name for primary interface (e.g., "card1")
get_primary_alsa_card() {
    local primary=$(get_primary_audio_interface)
    if [ -n "$primary" ]; then
        echo "$primary" | cut -d'|' -f1
    fi
}

# Get ALSA card ID for primary interface (e.g., "M4")
get_primary_alsa_id() {
    local primary=$(get_primary_audio_interface)
    if [ -n "$primary" ]; then
        echo "$primary" | cut -d'|' -f2
    fi
}

# Get USB path for primary interface
get_primary_usb_path() {
    local primary=$(get_primary_audio_interface)
    if [ -n "$primary" ]; then
        echo "$primary" | cut -d'|' -f3
    fi
}

# Get friendly name for primary interface
get_primary_interface_name() {
    local primary=$(get_primary_audio_interface)
    if [ -n "$primary" ]; then
        echo "$primary" | cut -d'|' -f5
    fi
}

# Force re-detection of interfaces
refresh_audio_interfaces() {
    DETECTED_INTERFACES=()
    detect_usb_audio_interfaces
}
