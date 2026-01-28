#!/bin/bash

# Realtime Audio Optimizer - System Tray Application
# Provides a system tray icon for status display and quick actions
#
# Usage:
#   rt-audio-tray         - Start the tray icon
#   rt-audio-tray --help  - Show help
#
# Requirements:
#   - yad (Yet Another Dialog) package
#   - Running desktop environment with system tray support
#
# The tray icon reads status from /var/run/rt-audio-tray-state
# which is written by the main optimizer service.

set -u

# ============================================================================
# CONFIGURATION
# ============================================================================

TRAY_NAME="Realtime Audio Optimizer"
STATE_FILE="${TRAY_STATE_FILE:-/var/run/rt-audio-tray-state}"
ICON_DIR="${TRAY_ICON_DIR:-/usr/share/icons/realtime-audio}"
UPDATE_INTERVAL="${TRAY_UPDATE_INTERVAL:-5}"
OPTIMIZER_CMD="realtime-audio-optimizer"

# FIFO for yad communication
FIFO_DIR="/tmp"
FIFO_NAME="rt-audio-tray-$(id -u)"
FIFO_PATH="${FIFO_DIR}/${FIFO_NAME}"

# Icons
ICON_OPTIMIZED="${ICON_DIR}/motu-optimized.svg"
ICON_CONNECTED="${ICON_DIR}/motu-connected.svg"
ICON_WARNING="${ICON_DIR}/motu-warning.svg"
ICON_DISCONNECTED="${ICON_DIR}/motu-disconnected.svg"

# Audio Interface detection (generic - any USB audio device)

# PID tracking
YAD_PID=""
MONITOR_PID=""

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

show_help() {
    cat << EOF
$TRAY_NAME - System Tray Application

Usage: $(basename "$0") [OPTIONS]

Options:
  --help, -h      Show this help message
  --version, -v   Show version information

Description:
  Displays a system tray icon showing the current status of the
  Realtime Audio Optimizer. Right-click the icon for quick actions.

Menu Options:
  - Status anzeigen     : Show detailed status in terminal
  - Live Xrun-Monitor   : Open live xrun monitoring
  - Optimierung starten : Activate audio optimizations
  - Optimierung stoppen : Deactivate optimizations
  - Beenden             : Close the tray icon

Requirements:
  - yad package (Yet Another Dialog)
  - Desktop environment with system tray support

Configuration:
  The tray reads status from: $STATE_FILE
  Icons are loaded from: $ICON_DIR

EOF
}

show_version() {
    echo "$TRAY_NAME - Tray Application v1.0"
}

check_dependencies() {
    if ! command -v yad &> /dev/null; then
        echo "Error: yad is not installed."
        echo "Install it with: sudo apt install yad"
        exit 1
    fi
}

# Check if any USB Audio Interface is connected (independent of daemon state file)
# This allows the tray to detect device status even when daemon is not running
check_rt_audio_connected() {
    # Check ALSA cards for USB audio devices
    for card in /proc/asound/card*; do
        # Check for usbid file (present for USB audio devices)
        if [ -e "$card/usbid" ]; then
            echo "true"
            return
        fi

        # Alternative: check usbbus file
        if [ -e "$card/usbbus" ]; then
            echo "true"
            return
        fi

        # Alternative: check stream0 for USB Audio signature
        if [ -e "$card/stream0" ] && grep -q "USB Audio" "$card/stream0" 2>/dev/null; then
            echo "true"
            return
        fi
    done

    echo "false"
}

# Get current icon based on actual device status and state file
get_current_icon() {
    # First check actual device connection (takes priority over state file)
    local motu_connected
    motu_connected=$(check_rt_audio_connected)

    if [ "$motu_connected" = "false" ]; then
        echo "$ICON_DISCONNECTED"
        return
    fi

    # Device is connected - check state file for optimization status
    local state="connected"
    if [ -f "$STATE_FILE" ]; then
        state=$(grep "^state=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    fi

    case "$state" in
        optimized)
            echo "$ICON_OPTIMIZED"
            ;;
        warning)
            echo "$ICON_WARNING"
            ;;
        connected|*)
            echo "$ICON_CONNECTED"
            ;;
    esac
}

# Get tooltip text based on actual device status and state file
# Returns a single-line tooltip (yad doesn't support multi-line tooltips well)
get_tooltip() {
    local tooltip="$TRAY_NAME"

    # First check actual device connection
    local motu_connected
    motu_connected=$(check_rt_audio_connected)

    if [ "$motu_connected" = "false" ]; then
        echo "$tooltip | Getrennt"
        return
    fi

    # Device is connected - read additional info from state file
    local state="connected"
    local jack="inactive"
    local jack_settings="unknown"
    local xruns="0"

    if [ -f "$STATE_FILE" ]; then
        state=$(grep "^state=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        jack=$(grep "^jack=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        jack_settings=$(grep "^jack_settings=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        xruns=$(grep "^xruns_30s=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    fi

    case "$state" in
        optimized)
            tooltip+=" | Optimiert"
            ;;
        warning)
            tooltip+=" | Warnung!"
            ;;
        connected|*)
            tooltip+=" | Verbunden"
            ;;
    esac

    if [ "$jack" = "active" ] && [ "$jack_settings" != "unknown" ]; then
        tooltip+=" | JACK: $jack_settings"
    fi

    if [ "$xruns" != "0" ] && [ -n "$xruns" ]; then
        tooltip+=" | Xruns: $xruns"
    fi

    echo "$tooltip"
}

# ============================================================================
# MENU ACTIONS
# ============================================================================
# Note: These functions are exported and called by yad via menu commands.
# ShellCheck SC2317 warnings about unreachable code can be ignored.

# shellcheck disable=SC2317
action_status() {
    # Open terminal with status display
    if command -v x-terminal-emulator &> /dev/null; then
        x-terminal-emulator -e bash -c "$OPTIMIZER_CMD status; echo ''; echo 'Druecke Enter zum Schliessen...'; read" &
    elif command -v gnome-terminal &> /dev/null; then
        gnome-terminal -- bash -c "$OPTIMIZER_CMD status; echo ''; echo 'Druecke Enter zum Schliessen...'; read" &
    elif command -v xterm &> /dev/null; then
        xterm -e "$OPTIMIZER_CMD status; echo ''; echo 'Druecke Enter zum Schliessen...'; read" &
    else
        notify-send "$TRAY_NAME" "Kein Terminal gefunden" 2>/dev/null
    fi
}

# shellcheck disable=SC2317
action_live_monitor() {
    # Open terminal with live xrun monitoring
    if command -v x-terminal-emulator &> /dev/null; then
        x-terminal-emulator -e bash -c "$OPTIMIZER_CMD live-xruns" &
    elif command -v gnome-terminal &> /dev/null; then
        gnome-terminal -- bash -c "$OPTIMIZER_CMD live-xruns" &
    elif command -v xterm &> /dev/null; then
        xterm -e "$OPTIMIZER_CMD live-xruns" &
    else
        notify-send "$TRAY_NAME" "Kein Terminal gefunden" 2>/dev/null
    fi
}

# shellcheck disable=SC2317
action_start_optimization() {
    # Start optimization (requires root)
    if command -v pkexec &> /dev/null; then
        pkexec "$OPTIMIZER_CMD" once
        notify-send -i "$ICON_OPTIMIZED" "$TRAY_NAME" "Optimierung gestartet" 2>/dev/null
    else
        notify-send -i "dialog-error" "$TRAY_NAME" "pkexec nicht verfuegbar" 2>/dev/null
    fi
}

# shellcheck disable=SC2317
action_stop_optimization() {
    # Stop optimization (requires root)
    if command -v pkexec &> /dev/null; then
        pkexec "$OPTIMIZER_CMD" stop
        notify-send -i "$ICON_DISCONNECTED" "$TRAY_NAME" "Optimierung gestoppt" 2>/dev/null
    else
        notify-send -i "dialog-error" "$TRAY_NAME" "pkexec nicht verfuegbar" 2>/dev/null
    fi
}

# ============================================================================
# TRAY MANAGEMENT
# ============================================================================

# Show popup menu on left-click (called via --command)
# Uses yad --list to display a clickable menu dialog
# shellcheck disable=SC2317
show_popup_menu() {
    local choice
    choice=$(yad --list \
        --title="$TRAY_NAME" \
        --width=280 \
        --height=320 \
        --column="Aktion" \
        --no-headers \
        --print-column=1 \
        --button="Schliessen:1" \
        "Status anzeigen" \
        "Live Xrun-Monitor" \
        "Daemon-Monitor" \
        "---" \
        "Optimierung starten" \
        "Optimierung stoppen" \
        2>/dev/null)

    case "$choice" in
        "Status anzeigen"*)
            x-terminal-emulator -e bash -c "$OPTIMIZER_CMD status; echo; read -p 'Druecke Enter...'" &
            ;;
        "Live Xrun-Monitor"*)
            x-terminal-emulator -e "$OPTIMIZER_CMD" live-xruns &
            ;;
        "Daemon-Monitor"*)
            x-terminal-emulator -e bash -c "pkexec $OPTIMIZER_CMD monitor" &
            ;;
        "Optimierung starten"*)
            pkexec "$OPTIMIZER_CMD" once &
            ;;
        "Optimierung stoppen"*)
            pkexec "$OPTIMIZER_CMD" stop &
            ;;
    esac
}
export -f show_popup_menu
export OPTIMIZER_CMD TRAY_NAME

cleanup() {
    # Clean up on exit
    [ -n "$YAD_PID" ] && kill "$YAD_PID" 2>/dev/null
    [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null
    [ -p "$FIFO_PATH" ] && rm -f "$FIFO_PATH"
    exit 0
}

# Monitor device status and state file, update tray accordingly
# Uses file descriptor 3 which must be opened before calling this function
state_monitor() {
    local last_state=""
    local last_xruns="0"
    local last_motu_connected=""

    while true; do
        # Check actual device connection (independent of state file)
        local motu_connected
        motu_connected=$(check_rt_audio_connected)

        # Determine current effective state
        local current_state="disconnected"
        local current_xruns="0"

        if [ "$motu_connected" = "true" ]; then
            # Device connected - read state file for optimization status
            if [ -f "$STATE_FILE" ]; then
                current_state=$(grep "^state=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
                current_xruns=$(grep "^xruns_30s=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
            else
                current_state="connected"
            fi
        else
            current_state="disconnected"
        fi

        # Update icon if device connection or state changed
        if [ "$motu_connected" != "$last_motu_connected" ] || [ "$current_state" != "$last_state" ]; then
            local new_icon
            new_icon=$(get_current_icon)
            echo "icon:$new_icon" >&3

            # Update tooltip
            local tooltip
            tooltip=$(get_tooltip)
            echo "tooltip:$tooltip" >&3

            last_motu_connected="$motu_connected"
            last_state="$current_state"
        fi

        # Check for xrun increase (only when device is connected)
        if [ "$motu_connected" = "true" ]; then
            if [ "$current_xruns" != "$last_xruns" ] && [ "$current_xruns" -gt 0 ] 2>/dev/null; then
                if [ "$current_xruns" -gt "${last_xruns:-0}" ]; then
                    # Show warning icon temporarily
                    echo "icon:$ICON_WARNING" >&3
                    sleep 2
                    # Restore normal icon
                    local restore_icon
                    restore_icon=$(get_current_icon)
                    echo "icon:$restore_icon" >&3
                fi
                last_xruns="$current_xruns"
            fi
        fi

        sleep "$UPDATE_INTERVAL"
    done
}

start_tray() {
    # Set up signal handlers
    trap cleanup EXIT INT TERM

    # Create FIFO for communication
    rm -f "$FIFO_PATH"
    mkfifo "$FIFO_PATH"

    # Get initial icon
    local initial_icon
    initial_icon=$(get_current_icon)

    # Build menu with direct shell commands
    # Format: "Label!command|Label2!command2|..."
    # Note: yad executes these as shell commands, so we use full paths and inline commands
    local menu="Status anzeigen!x-terminal-emulator -e bash -c '${OPTIMIZER_CMD} status; echo; read -p \"Druecke Enter...\"'"
    menu+="|Live Xrun-Monitor!x-terminal-emulator -e ${OPTIMIZER_CMD} live-xruns"
    menu+="|Daemon-Monitor!x-terminal-emulator -e bash -c 'pkexec ${OPTIMIZER_CMD} monitor'"
    menu+="|---"
    menu+="|Optimierung starten!pkexec ${OPTIMIZER_CMD} once"
    menu+="|Optimierung stoppen!pkexec ${OPTIMIZER_CMD} stop"
    menu+="|---"
    menu+="|Beenden!quit"

    # Open FIFO for read/write on file descriptor 3 BEFORE starting monitor
    # This ensures the monitor can write to it
    exec 3<> "$FIFO_PATH"

    # Start yad notification icon reading from FIFO
    # Use exec -a to set process name for KDE system tray display
    (exec -a "RT-Audio-Optimizer" yad --notification \
        --image="$initial_icon" \
        --text="$TRAY_NAME" \
        --menu="$menu" \
        --command="bash -c show_popup_menu" \
        --class="rt-audio-optimizer" \
        --name="rt-audio-optimizer" \
        --listen) <&3 &

    YAD_PID=$!

    # Give yad time to initialize before sending commands
    sleep 0.5

    # Send initial tooltip immediately
    local tooltip
    tooltip=$(get_tooltip)
    echo "tooltip:$tooltip" >&3

    # Start state monitor in background (uses fd 3 for writing)
    state_monitor &
    MONITOR_PID=$!

    # Wait for yad to exit
    wait $YAD_PID

    cleanup
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --version|-v)
        show_version
        exit 0
        ;;
    "")
        check_dependencies
        start_tray
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
