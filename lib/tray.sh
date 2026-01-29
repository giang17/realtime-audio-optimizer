#!/bin/bash

# Realtime Audio Optimizer - Tray Module
# Provides functions for system tray integration
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   tray_check_dependencies()
#     Checks if yad is installed for tray support.
#     @return   : 0 if yad is available, 1 otherwise
#     @stdout   : None
#
#   tray_is_enabled()
#     Checks if tray is enabled in configuration.
#     @return   : 0 if enabled, 1 if disabled
#     @requires : TRAY_ENABLED variable from config.sh
#
#   tray_write_state(state, motu, jack, jack_settings, xruns)
#     Writes current status to tray state file for tray application to read.
#     @param  state         : string - "optimized"|"connected"|"disconnected"|"warning"
#     @param  motu          : string - "connected"|"disconnected"
#     @param  jack          : string - "active"|"inactive"
#     @param  jack_settings : string - e.g., "256@48000Hz"
#     @param  xruns         : int    - xrun count in last 30s
#     @return               : 0 on success, 1 on failure
#     @writes               : TRAY_STATE_FILE
#
#   tray_get_state_file()
#     Returns the path to the tray state file.
#     @return   : void
#     @stdout   : Path to state file
#
#   tray_notify(title, message, icon)
#     Sends a desktop notification if yad is available.
#     @param  title   : string - Notification title
#     @param  message : string - Notification body
#     @param  icon    : string - Icon name or path (optional)
#     @return         : 0 on success, 1 if yad not available
#
# DEPENDENCIES:
#   - config.sh (TRAY_ENABLED, TRAY_STATE_FILE, TRAY_NOTIFY_ON_XRUN)
#   - logging.sh (log_debug) - optional, for debug output
#
# ============================================================================

# Check if yad is installed
# Returns 0 if available, 1 otherwise
tray_check_dependencies() {
    command -v yad &> /dev/null
}

# Check if tray state writing is enabled in configuration
# Returns 0 if enabled, 1 if disabled
# Note: This only controls whether the state file is written.
#       The PyQt5 tray application can still read state from optimizer output.
tray_is_enabled() {
    # Check if TRAY_ENABLED is set and true
    if [ "${TRAY_ENABLED:-false}" != "true" ]; then
        return 1
    fi

    # Note: We don't check for yad anymore because:
    # 1. The PyQt5 tray doesn't need yad
    # 2. State file is useful for any tray implementation
    return 0
}

# Get the tray state file path
tray_get_state_file() {
    echo "${TRAY_STATE_FILE:-/var/run/realtime-audio-tray-state}"
}

# Write current status to tray state file
# Args: state, motu, jack, jack_settings, xruns
# Note: Always writes state file so any tray application can read it
tray_write_state() {
    local state="${1:-disconnected}"
    local motu="${2:-disconnected}"
    local jack="${3:-inactive}"
    local jack_settings="${4:-unknown}"
    local xruns="${5:-0}"

    local state_file
    state_file=$(tray_get_state_file)

    # Write state file atomically (write to temp, then move)
    local temp_file="${state_file}.tmp"

    if {
        echo "state=${state}"
        echo "motu=${motu}"
        echo "jack=${jack}"
        echo "jack_settings=${jack_settings}"
        echo "xruns_30s=${xruns}"
        echo "last_update=$(date +%s)"
    } > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$state_file" 2>/dev/null
        chmod 644 "$state_file" 2>/dev/null

        # Debug log if function is available
        if declare -f log_debug &> /dev/null; then
            log_debug "Tray state updated: state=$state, motu=$motu, jack=$jack"
        fi
        return 0
    else
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
}

# Read a value from the tray state file
# Args: key
# Returns: value via stdout
tray_read_state() {
    local key="$1"
    local state_file
    state_file=$(tray_get_state_file)

    if [ -f "$state_file" ]; then
        grep "^${key}=" "$state_file" 2>/dev/null | cut -d'=' -f2
    fi
}

# Send a desktop notification
# Args: title, message, icon (optional)
tray_notify() {
    local title="$1"
    local message="$2"
    local icon="${3:-audio-card}"

    # Check if notifications are enabled and yad is available
    if ! tray_check_dependencies; then
        return 1
    fi

    # Use notify-send if available (more reliable for notifications)
    if command -v notify-send &> /dev/null; then
        notify-send -i "$icon" "$title" "$message" 2>/dev/null
        return $?
    fi

    # Fallback to yad notification
    yad --notification \
        --image="$icon" \
        --text="$title: $message" \
        --command=":" \
        --timeout=5 2>/dev/null &

    return 0
}

# Notify on xrun if enabled
# Args: xrun_count
tray_notify_xrun() {
    local xrun_count="$1"

    # Check if xrun notifications are enabled
    if [ "${TRAY_NOTIFY_ON_XRUN:-true}" != "true" ]; then
        return 0
    fi

    if [ "$xrun_count" -gt 0 ]; then
        tray_notify "Audio Optimizer" "$xrun_count xruns in the last 30 seconds" "dialog-warning"
    fi
}

# Determine the appropriate icon based on state
# Args: state
# Returns: icon path via stdout
tray_get_icon_for_state() {
    local state="$1"
    local icon_dir="${TRAY_ICON_DIR:-/usr/share/icons/realtime-audio}"

    case "$state" in
        optimized)
            echo "${icon_dir}/motu-optimized.svg"
            ;;
        connected)
            echo "${icon_dir}/motu-connected.svg"
            ;;
        warning)
            echo "${icon_dir}/motu-warning.svg"
            ;;
        disconnected|*)
            echo "${icon_dir}/motu-disconnected.svg"
            ;;
    esac
}

# Clean up tray state file
tray_cleanup() {
    local state_file
    state_file=$(tray_get_state_file)
    rm -f "$state_file" 2>/dev/null
}
