#!/bin/bash

# Realtime Audio Optimizer - Monitor Module
# Contains monitoring loops for continuous and live xrun monitoring
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   main_monitoring_loop()
#     Continuous monitoring loop for systemd service.
#     @return   : never (infinite loop)
#     @requires : Root privileges
#     @stdout   : Log messages via log_info(), log_warn(), log_debug()
#     @behavior :
#       - Every 5s: Check audio interface connection
#       - Every 30s: Re-apply process affinity
#       - Every 10s: Monitor and log xruns
#
#   live_xrun_monitoring()
#     Interactive real-time xrun monitoring.
#     @return   : never (infinite loop, exit with Ctrl+C)
#     @stdout   : Real-time status line updated every 2s
#     @display  : [TIME] STATUS | Audio Interface | Audio | JACK | Session | 30s | Max | Timer
#
#   delayed_service_start()
#     Boot-time optimization with wait for user audio services.
#     @return   : void
#     @requires : Root privileges
#     @waits    : Up to MAX_AUDIO_WAIT seconds for PipeWire/JACK
#     @calls    : activate_audio_optimizations or deactivate_audio_optimizations
#
# PRIVATE FUNCTIONS:
#
#   _check_and_report_xruns(last_count)
#     Checks xruns and logs warnings if threshold exceeded.
#     @param  last_count : int - Previous xrun count
#     @exit              : Current xrun count (capped at 255)
#     @stdout            : Warning messages via log_warn(), log_info()
#
#   _show_live_monitor_jack_info()
#     Displays JACK status at live monitor start.
#     @stdout : JACK settings and buffer warnings
#
#   _live_monitor_cycle(initial_xruns, session_start, max_xruns, timestamps...)
#     Single update cycle for live monitoring.
#     @param  initial_xruns : int - Baseline xrun count at session start
#     @param  session_start : int - Unix epoch timestamp
#     @param  max_xruns     : int - Maximum xruns seen this session
#     @param  timestamps    : array - Recent xrun timestamps for 30s rate
#     @stdout               : Updated status line via printf
#
#   _show_live_xrun_details(time, new_xruns, rate)
#     Shows xrun details and recommendations on xrun events.
#     @param  time      : string - Display time
#     @param  new_xruns : int - New xruns in this interval
#     @param  rate      : int - 30-second xrun rate
#     @stdout           : Xrun details and buffer recommendations
#
# LOOP TIMING:
#
#   main_monitoring_loop:
#     - Base interval: MONITOR_INTERVAL (5s)
#     - Process check: Every 6 cycles (30s)
#     - Xrun check: Every 2 cycles (10s)
#
#   live_xrun_monitoring:
#     - Update interval: 2s
#     - Rate window: 30s rolling
#
# DEPENDENCIES:
#   - config.sh (OPTIMIZER_NAME, OPTIMIZER_VERSION, OPTIMIZER_STRATEGY,
#                DAW_CPUS, AUDIO_MAIN_CPUS, IRQ_CPUS, BACKGROUND_CPUS,
#                MONITOR_INTERVAL, MAX_AUDIO_WAIT, XRUN_WARNING_THRESHOLD)
#   - logging.sh (log_info, log_warn, log_debug)
#   - checks.sh (check_audio_interfaces, check_cpu_isolation)
#   - jack.sh (get_jack_settings, calculate_latency_ms, get_jack_compact_info)
#   - process.sh (optimize_script_performance, optimize_audio_process_affinity)
#   - optimization.sh (activate_audio_optimizations, deactivate_audio_optimizations)
#
# ============================================================================
# MAIN MONITORING LOOP
# ============================================================================
#
# The main monitoring loop runs continuously as a system service.
# It periodically checks for audio interface connection and maintains optimizations.
#
# Loop behavior:
#   - Every 5 seconds: Check audio interface connection, activate/deactivate as needed
#   - Every 30 seconds: Re-apply process affinity (catches new audio processes)
#   - Every 10 seconds: Monitor for xruns and log warnings

# Main monitoring loop for continuous optimization
# Runs indefinitely, monitoring audio interface connection and xrun activity.
# This is the main entry point when running as a systemd service.
#
# The loop:
#   1. Checks if audio interface is connected
#   2. Activates optimizations when connected (if not already active)
#   3. Periodically re-applies process affinity for new processes
#   4. Monitors xruns and logs warnings when thresholds exceeded
#   5. Deactivates optimizations when audio interface is disconnected
main_monitoring_loop() {
    log_info "🚀 $OPTIMIZER_NAME v$OPTIMIZER_VERSION started"
    log_info "🏗️  $OPTIMIZER_STRATEGY"
    log_info "📊 System: Ubuntu 24.04, $(nproc) CPU cores"
    log_debug "🎯 Process pinning:"
    log_debug "   P-Cores DAW/Plugins: $DAW_CPUS"
    log_debug "   P-Cores JACK/PipeWire: $AUDIO_MAIN_CPUS"
    log_debug "   E-Cores IRQ-Handling: $IRQ_CPUS"
    log_debug "   E-Cores Background: $BACKGROUND_CPUS"
    log_info "🎵 Xrun monitoring: Activated"

    # Optimize script performance (run on background E-Cores)
    optimize_script_performance

    # Initial CPU isolation check (suppress output, info already in log_debug)
    check_cpu_isolation > /dev/null

    local current_state="unknown"
    local check_counter=0
    local xrun_check_counter=0
    local last_xrun_count=0

    while true; do
        local motu_connected
        motu_connected=$(check_audio_interfaces)

        if [ "$motu_connected" = "true" ]; then
            if [ "$current_state" != "optimized" ]; then
                activate_audio_optimizations
                current_state="optimized"
                check_counter=0
            else
                # Check process affinity only every 30 seconds (performance optimization)
                check_counter=$((check_counter + 1))
                if [ $check_counter -ge 6 ]; then
                    optimize_audio_process_affinity
                    check_counter=0
                fi
            fi

            # Xrun monitoring every 10 seconds (2 cycles)
            xrun_check_counter=$((xrun_check_counter + 1))
            if [ $xrun_check_counter -ge 2 ]; then
                _check_and_report_xruns "$last_xrun_count"
                last_xrun_count=$?
                xrun_check_counter=0

                # Update tray state with xrun count
                if declare -f tray_write_state &> /dev/null && declare -f tray_is_enabled &> /dev/null; then
                    if tray_is_enabled; then
                        local tray_state="optimized"
                        local jack_settings="unknown"
                        if declare -f get_jack_compact_info &> /dev/null; then
                            jack_settings=$(get_jack_compact_info 2>/dev/null || echo "unknown")
                        fi
                        # Set warning state if xruns detected
                        if [ "$last_xrun_count" -gt "$XRUN_WARNING_THRESHOLD" ]; then
                            tray_state="warning"
                        fi
                        tray_write_state "$tray_state" "connected" "active" "$jack_settings" "$last_xrun_count"

                        # Send xrun notification if enabled
                        if [ "$last_xrun_count" -gt 0 ] && declare -f tray_notify_xrun &> /dev/null; then
                            tray_notify_xrun "$last_xrun_count"
                        fi
                    fi
                fi
            fi
        else
            if [ "$current_state" != "standard" ]; then
                deactivate_audio_optimizations
                current_state="standard"
            fi
        fi

        sleep "$MONITOR_INTERVAL"
    done
}

# Check and report xruns during monitoring
# Args: $1 = last xrun count
# Returns: current xrun count via exit code (capped at 255)
_check_and_report_xruns() {
    local last_count="$1"

    if ! command -v journalctl &> /dev/null; then
        return 0
    fi

    # Check xruns of last 30 seconds
    local current_xruns
    current_xruns=$(journalctl --since "30 seconds ago" --no-pager -q 2>/dev/null | \
        grep -i "mod\.jack-tunnel.*xrun" | wc -l || echo "0")

    if [ "$current_xruns" -gt "$XRUN_WARNING_THRESHOLD" ]; then
        log_warn "⚠️ Xrun-Warning: $current_xruns Xruns in 30s (Threshold: $XRUN_WARNING_THRESHOLD)"
        log_warn "💡 Recommendation: Increase buffer size or reduce CPU load"
    elif [ "$current_xruns" -gt 0 ] && [ "$current_xruns" -ne "$last_count" ]; then
        log_info "🎵 Xrun-Monitor: $current_xruns Xruns in last 30s"
    fi

    # Return current count (capped at 255 for exit code)
    [ "$current_xruns" -gt 255 ] && current_xruns=255
    return "$current_xruns"
}

# ============================================================================
# LIVE XRUN MONITORING
# ============================================================================
#
# Live monitoring provides real-time xrun feedback for interactive use.
# It displays a continuously updating status line showing:
#   - Current audio interface and audio process status
#   - Session xrun count and recent xrun rate
#   - Dynamic recommendations when xruns occur

# Live xrun monitoring with improved PipeWire-JACK-Tunnel detection
# Interactive monitoring mode that updates every 2 seconds.
# Shows real-time xrun statistics and provides immediate feedback.
#
# Display format:
#   [TIME] STATUS Audio Interface: Connected | Audio: N | JACK: 256@48kHz | Session: N | 30s: N | Max: N | Timer
#
# Press Ctrl+C to exit.
live_xrun_monitoring() {
    echo "=== audio interface Live Xrun-Monitor ==="
    echo "⚡ Monitors JACK/PipeWire xruns in real-time"
    echo "📊 Session started: $(date '+%H:%M:%S')"

    # Show current JACK settings at session start
    _show_live_monitor_jack_info

    echo "🛑 Press Ctrl+C to exit"
    echo ""

    # Print placeholder lines for multi-line update mode (narrow terminals)
    local term_width
    term_width=$(tput cols 2>/dev/null || echo "80")
    if [ "$term_width" -lt 100 ]; then
        echo ""  # Placeholder line 1
        echo ""  # Placeholder line 2
    fi

    # Initial xrun counter from current log state
    local initial_xruns=0
    if command -v journalctl &> /dev/null; then
        initial_xruns=$(journalctl --since "1 minute ago" --no-pager -q 2>/dev/null | \
            grep -i "mod\.jack-tunnel.*xrun" | wc -l || echo "0")
    fi

    local xrun_total=0
    local xrun_session_start
    xrun_session_start=$(date +%s)
    local max_xruns_per_interval=0

    # Xrun rate tracking for last 30 seconds
    local xrun_timestamps=()

    while true; do
        _live_monitor_cycle "$initial_xruns" "$xrun_session_start" "$max_xruns_per_interval" "${xrun_timestamps[@]}"
        sleep 2
    done
}

# Show JACK info at live monitor start
_show_live_monitor_jack_info() {
    local jack_info
    jack_info=$(get_jack_settings)
    local jack_status bufsize samplerate nperiods
    jack_status=$(echo "$jack_info" | cut -d'|' -f1)
    bufsize=$(echo "$jack_info" | cut -d'|' -f2)
    samplerate=$(echo "$jack_info" | cut -d'|' -f3)
    nperiods=$(echo "$jack_info" | cut -d'|' -f4)

    echo "🎵 JACK Status: $jack_status"
    if [ "$jack_status" = "✅ Active" ]; then
        local settings_text="${bufsize}@${samplerate}Hz"
        [ "$nperiods" != "unknown" ] && settings_text="$settings_text, $nperiods periods"

        local latency_ms
        latency_ms=$(calculate_latency_ms "$bufsize" "$samplerate")
        echo "   Settings: $settings_text (${latency_ms}ms Latency)"

        # Warning for aggressive settings
        if [ "$bufsize" != "unknown" ]; then
            if [ "$bufsize" -le 64 ]; then
                echo "   ⚠️ Very aggressive buffer size - Xruns likely"
            elif [ "$bufsize" -le 128 ]; then
                echo "   🟡 Moderate buffer size - Increase to 256+ if xruns occur"
            fi
        fi
    fi
}

# Single cycle of live monitoring
# Performs one update cycle: queries journalctl, updates display, shows alerts.
#
# Args:
#   $1 - Initial xrun count at session start (baseline)
#   $2 - Session start timestamp (Unix epoch seconds)
#   $3 - Maximum xruns seen in any interval this session
#   $4+ - Array of recent xrun timestamps (for 30s rate calculation)
_live_monitor_cycle() {
    local initial_xruns="$1"
    local xrun_session_start="$2"
    local max_xruns_per_interval="$3"
    shift 3
    local xrun_timestamps=("$@")

    # Current xruns from logs since session start
    local current_total_xruns=0
    local new_xruns_this_interval=0

    if command -v journalctl &> /dev/null; then
        # All xruns since session start
        local session_start_time
        session_start_time=$(date -d "@$xrun_session_start" '+%Y-%m-%d %H:%M:%S')
        current_total_xruns=$(journalctl --since "$session_start_time" --no-pager -q 2>/dev/null | \
            grep -i "mod\.jack-tunnel.*xrun" | wc -l || echo "0")

        # New xruns of last 5 seconds
        new_xruns_this_interval=$(journalctl --since "5 seconds ago" --no-pager -q 2>/dev/null | \
            grep -i "mod\.jack-tunnel.*xrun" | wc -l || echo "0")
    fi

    # Session xruns (minus initial)
    local xrun_total=$((current_total_xruns - initial_xruns))
    [ "$xrun_total" -lt 0 ] && xrun_total=0

    # Tracking for new xruns
    local current_timestamp
    current_timestamp=$(date +%s)
    if [ "$new_xruns_this_interval" -gt 0 ]; then
        xrun_timestamps+=("$current_timestamp")
    fi

    # Remove old timestamps (older than 30 seconds)
    local cutoff_time=$((current_timestamp - 30))
    local new_timestamps=()
    for ts in "${xrun_timestamps[@]}"; do
        if [ "$ts" -gt "$cutoff_time" ]; then
            new_timestamps+=("$ts")
        fi
    done
    xrun_timestamps=("${new_timestamps[@]}")

    # Xrun rate in last 30 seconds
    local xrun_rate_30s=${#xrun_timestamps[@]}

    # Max xruns per interval tracking
    if [ "$new_xruns_this_interval" -gt "$max_xruns_per_interval" ]; then
        max_xruns_per_interval=$new_xruns_this_interval
    fi

    # Audio process info (uses AUDIO_GREP_PATTERN from config)
    local audio_processes
    audio_processes=$(ps -eo pid,comm --no-headers 2>/dev/null | \
        grep -iE "$AUDIO_GREP_PATTERN" | wc -l)

    # audio interface status
    local motu_status="❌ Not detected"
    if [ "$(check_audio_interfaces)" = "true" ]; then
        motu_status="✅ Connected"
    fi

    # Session time
    local session_duration=$((current_timestamp - xrun_session_start))
    local session_minutes=$((session_duration / 60))
    local session_seconds=$((session_duration % 60))

    # Status icon based on current xruns
    local status_icon="✅"
    [ "$new_xruns_this_interval" -gt 0 ] && status_icon="⚠️"
    [ "$new_xruns_this_interval" -gt 2 ] && status_icon="❌"

    # Live display with JACK settings (compact, multi-line for readability)
    local current_display_time
    current_display_time=$(date '+%H:%M:%S')

    # Compact JACK info for live display
    local jack_compact
    jack_compact=$(get_jack_compact_info)

    # Get terminal width for adaptive display
    local term_width
    term_width=$(tput cols 2>/dev/null || echo "80")

    # Clear line and move cursor up for update (multi-line display)
    # Use ANSI escape codes: \033[K = clear to end of line, \033[A = move up
    if [ "$term_width" -lt 100 ]; then
        # Compact multi-line format for narrow terminals
        printf "\033[2A\033[K[%s] %s Audio Interface: %s | Audio: %d\n" \
               "$current_display_time" "$status_icon" "$motu_status" "$audio_processes"
        printf "\033[K%s | Xruns: %d | 30s: %d | Max: %d | %02d:%02d\n" \
               "$jack_compact" "$xrun_total" "$xrun_rate_30s" "$max_xruns_per_interval" \
               "$session_minutes" "$session_seconds"
    else
        # Single-line format for wide terminals
        printf "\r\033[K[%s] %s Audio Interface: %s | Audio: %d | %s | Xruns: %d | 30s: %d | Max: %d | %02d:%02d" \
               "$current_display_time" "$status_icon" "$motu_status" "$audio_processes" "$jack_compact" \
               "$xrun_total" "$xrun_rate_30s" "$max_xruns_per_interval" "$session_minutes" "$session_seconds"
    fi

    # On new xruns: New line with details and recommendations
    if [ "$new_xruns_this_interval" -gt 0 ]; then
        echo ""
        _show_live_xrun_details "$current_display_time" "$new_xruns_this_interval" "$xrun_rate_30s"
    fi
}

# Show xrun details during live monitoring
_show_live_xrun_details() {
    local display_time="$1"
    local new_xruns="$2"
    local xrun_rate="$3"

    # Show the latest xrun message
    echo "🚨 [$display_time] New xruns: $new_xruns"

    local latest_xrun
    latest_xrun=$(journalctl --since "5 seconds ago" --no-pager -q 2>/dev/null | \
        grep -i "mod\.jack-tunnel.*xrun" | tail -1)

    if [ -n "$latest_xrun" ]; then
        local xrun_details
        xrun_details=$(echo "$latest_xrun" | cut -d' ' -f5-)
        echo "📋 Details: $xrun_details"
    fi

    # Dynamic recommendation on xruns
    local jack_info
    jack_info=$(get_jack_settings)
    local jack_status bufsize samplerate nperiods
    jack_status=$(echo "$jack_info" | cut -d'|' -f1)
    bufsize=$(echo "$jack_info" | cut -d'|' -f2)
    samplerate=$(echo "$jack_info" | cut -d'|' -f3)
    nperiods=$(echo "$jack_info" | cut -d'|' -f4)

    if [ "$jack_status" = "✅ Active" ] && [ "$bufsize" != "unknown" ]; then
        if [ "$bufsize" -le 64 ]; then
            echo "💡 Recommendation: Increase buffer from $bufsize to 128+ samples"
        elif [ "$bufsize" -le 128 ] && [ "$xrun_rate" -gt 5 ]; then
            echo "💡 Recommendation: Increase buffer from $bufsize to 256 samples"
        elif [ "$nperiods" != "unknown" ] && [ "$nperiods" -eq 2 ] && [ "$xrun_rate" -gt 3 ]; then
            echo "💡 Tip: Use 3 periods instead of $nperiods for better latency tolerance"
        fi
    fi
}

# ============================================================================
# DELAYED SERVICE START
# ============================================================================
#
# When started as a system service at boot, user audio services (PipeWire,
# JACK) may not be running yet. This function waits for them to appear
# before applying optimizations.

# Delayed optimization for system service (waits for user audio services)
# Waits up to MAX_AUDIO_WAIT seconds for PipeWire/JACK to start.
# This ensures process affinity optimizations are applied to user processes.
#
# Used by: systemd service (Type=oneshot with RemainAfterExit)
delayed_service_start() {
    local motu_connected
    motu_connected=$(check_audio_interfaces)

    if [ "$motu_connected" = "true" ]; then
        log_info "🎵 Delayed system service: Waiting for user session audio processes"

        # Intelligent wait time for user audio services
        local audio_wait=0
        local found_user_audio=false

        while [ $audio_wait -lt $MAX_AUDIO_WAIT ]; do
            # Check for user audio processes (not just system audio)
            local user_pipewire user_jack
            user_pipewire=$(pgrep -f "pipewire" | wc -l)
            user_jack=$(pgrep -f "jackdbus" | wc -l)

            if [ "$user_pipewire" -ge 2 ] || [ "$user_jack" -ge 1 ]; then
                log_info "🎯 User audio services detected after ${audio_wait}s (PipeWire: $user_pipewire, JACK: $user_jack)"
                found_user_audio=true
                break
            fi

            sleep 2
            audio_wait=$((audio_wait + 2))

            # Progress log every 10 seconds
            if [ $((audio_wait % 10)) -eq 0 ]; then
                log_debug "⏳ Waiting for user audio services... ${audio_wait}/${MAX_AUDIO_WAIT}s (PipeWire: $user_pipewire, JACK: $user_jack)"
            fi
        done

        if [ "$found_user_audio" = "true" ]; then
            # Additional 3 seconds for service initialization
            sleep 3
            log_info "🎵 Starting delayed audio optimization for user session processes"
            activate_audio_optimizations
        else
            log_warn "⚠️  Timeout: No user audio services after ${MAX_AUDIO_WAIT}s detected, starting standard optimization"
            activate_audio_optimizations
        fi
    else
        log_info "🔧 audio interface not detected - Deactivating optimizations"
        deactivate_audio_optimizations
    fi
}
