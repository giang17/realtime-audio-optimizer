#!/bin/bash

# Realtime Audio Optimizer - Xrun Module
# Contains functions for xrun monitoring, statistics, and analysis
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   get_xrun_stats()
#     Collects comprehensive xrun statistics from multiple sources.
#     @return : string - "jack:N|pipewire:N|total:N"
#     @stdout : Pipe-separated xrun counts
#     @note   : Takes ~5 seconds due to jack_test
#
#   get_live_jack_xruns()
#     Gets recent xrun count for real-time monitoring.
#     @return : int - Xrun count from last 10-15 seconds
#     @stdout : Count as string
#     @note   : Faster than get_xrun_stats()
#
#   get_system_xruns()
#     Gets system-wide xrun and error information.
#     @return : string - "recent:N|severe:N|jack_msg:N"
#     @stdout : Pipe-separated system xrun data
#
#   parse_xrun_stats(stats, field)
#     Extracts a field from xrun stats string.
#     @param  stats : string - Stats string (e.g., "jack:5|pipewire:3|total:8")
#     @param  field : string - Field name ("jack", "pipewire", "total")
#     @return       : int - Numeric value for the field
#     @stdout       : Field value
#
#   parse_system_xruns(stats, field)
#     Extracts a field from system xruns string.
#     @param  stats : string - Stats string
#     @param  field : string - "recent", "severe", or "jack_msg"
#     @return       : int - Numeric value for the field
#     @stdout       : Field value
#
#   get_xrun_severity(total_xruns, severe_xruns)
#     Determines xrun severity category.
#     @param  total_xruns  : int - Total xrun count
#     @param  severe_xruns : int - Hardware error count (optional, default 0)
#     @return              : string - "perfect", "mild", or "severe"
#     @stdout              : Severity string
#
#   get_xrun_icon(xrun_count)
#     Gets status icon based on xrun count.
#     @param  xrun_count : int - Xrun count
#     @return            : string - "✅", "⚠️", or "❌"
#     @stdout            : Status icon
#
#   calculate_xrun_rate(xrun_count, time_period)
#     Calculates xruns per minute.
#     @param  xrun_count  : int - Number of xruns
#     @param  time_period : int - Time period in seconds
#     @return             : float|int - Xruns per minute
#     @stdout             : Rate value
#
#   get_latest_xrun_message()
#     Gets most recent xrun log message.
#     @return : string - Xrun message or empty string
#     @stdout : Log message text
#
# RETURN VALUE FORMATS:
#
#   get_xrun_stats():
#     "jack:N|pipewire:N|total:N"
#     - jack: JACK xruns from jack_test, logs, QJackCtl
#     - pipewire: PipeWire-JACK-Tunnel xruns
#     - total: Sum of jack + pipewire
#
#   get_system_xruns():
#     "recent:N|severe:N|jack_msg:N"
#     - recent: Audio xruns in last 5 minutes
#     - severe: Hardware errors (USB disconnects, etc.)
#     - jack_msg: JACK-specific log messages
#
# DETECTION SOURCES:
#
#   JACK xruns:
#     - jack_test -t 5 (direct testing)
#     - jack_simple_client (fallback)
#     - journalctl JACK logs
#     - QJackCtl logs
#
#   PipeWire xruns:
#     - journalctl mod.jack-tunnel messages
#
#   System errors:
#     - journalctl audio/sound logs
#     - dmesg USB/audio errors
#
# DEPENDENCIES:
#   - External commands: journalctl, dmesg (optional), jack_test (optional),
#                        jack_simple_client (optional), bc (optional)
#
# ============================================================================
# XRUN STATISTICS COLLECTION
# ============================================================================
#
# Xruns (buffer underruns/overruns) occur when the audio buffer empties
# or overflows before being processed. They cause audible clicks/pops.
#
# Detection methods:
#   1. jack_test: Direct JACK server testing
#   2. journalctl: System log parsing for xrun messages
#   3. dmesg: Kernel messages for USB/audio errors
#
# Common xrun causes:
#   - Buffer size too small for system performance
#   - CPU scheduling latency (other processes interfering)
#   - USB bandwidth/power issues

# Collect comprehensive xrun statistics
# Uses multiple detection methods to find xruns from different sources.
# Combines JACK, PipeWire, and system log data.
#
# Returns: "jack:N|pipewire:N|total:N" (pipe-separated string)
#
# Note: This function runs jack_test which takes ~5 seconds
get_xrun_stats() {
    local jack_xruns=0
    local pipewire_xruns=0
    local jack_messages=0
    local total_xruns=0

    # Real JACK xrun detection with jack_test (if JACK is running)
    if pgrep -x "jackd\|jackdbus" > /dev/null 2>&1; then
        # Method 1: jack_test for real xrun statistics
        if command -v jack_test &> /dev/null; then
            # jack_test -t 5 runs 5 seconds and reports xruns
            local jack_test_output
            jack_test_output=$(timeout 7 jack_test -t 5 2>&1 || echo "timeout")
            jack_xruns=$(echo "$jack_test_output" | grep -i "xrun\|late\|early" | wc -l || echo "0")

            # Fallback: Look for "%" values indicating timing issues
            if [ "$jack_xruns" -eq 0 ]; then
                local timing_issues
                timing_issues=$(echo "$jack_test_output" | grep -E "[1-9][0-9]*\.[0-9]*%" | wc -l || echo "0")
                jack_xruns=$timing_issues
            fi
        fi

        # Method 2: jack_simple_client for live test (only if 0 xruns)
        if command -v jack_simple_client &> /dev/null && [ "$jack_xruns" -eq 0 ]; then
            local jack_client_test
            jack_client_test=$(timeout 3 jack_simple_client 2>&1 | grep -i "xrun\|buffer\|late" | wc -l || echo "0")
            jack_xruns=$((jack_xruns + jack_client_test))
        fi

        # Method 3: JACK logs from journalctl (last 2 minutes)
        if command -v journalctl &> /dev/null; then
            local jack_log_xruns
            jack_log_xruns=$(journalctl --since "2 minutes ago" --no-pager -q 2>/dev/null | grep -iE "(jack|qjackctl).*(xrun|underrun|delay.*exceeded|timeout|late)" | wc -l || echo "0")
            jack_xruns=$((jack_xruns + jack_log_xruns))
        fi

        # Method 4: QJackCtl-specific xrun detection
        if pgrep -x "qjackctl" > /dev/null 2>&1; then
            local qjackctl_logs
            qjackctl_logs=$(journalctl --since "1 minute ago" --no-pager -q 2>/dev/null | grep -i "qjackctl.*xrun.*count\|jack.*xrun.*detected" | wc -l || echo "0")
            jack_xruns=$((jack_xruns + qjackctl_logs))
        fi
    fi

    # PipeWire xrun detection via JACK tunnel logs
    if pgrep -x "pipewire" > /dev/null 2>&1; then
        if command -v journalctl &> /dev/null; then
            # Search for "mod.jack-tunnel: Xrun" messages from last 2 minutes
            pipewire_xruns=$(journalctl --since "2 minutes ago" --no-pager -q 2>/dev/null | grep -i "mod\.jack-tunnel.*xrun\|pipewire.*xrun\|pipewire.*drop\|pipewire.*underrun" | wc -l || echo "0")
        fi
    fi

    # Calculate total
    total_xruns=$((jack_xruns + pipewire_xruns))

    echo "jack:$jack_xruns|pipewire:$pipewire_xruns|total:$total_xruns"
}

# ============================================================================
# LIVE XRUN DETECTION
# ============================================================================
#
# Live detection focuses on very recent xruns (last 10-15 seconds).
# Used for real-time monitoring where quick feedback is important.

# Get live JACK xrun count (recent xruns for real-time monitoring)
# Faster than get_xrun_stats() as it only checks recent logs.
#
# Returns: xrun count from last 10-15 seconds
get_live_jack_xruns() {
    local xrun_count=0
    local pipewire_xruns=0

    # Priority: PipeWire-JACK-Tunnel xruns (commonly used)
    if pgrep -x "pipewire" > /dev/null 2>&1; then
        # PipeWire-JACK-Tunnel xruns of last 10 seconds (live detection)
        if command -v journalctl &> /dev/null; then
            pipewire_xruns=$(journalctl --since "10 seconds ago" --no-pager -q 2>/dev/null | grep -i "mod\.jack-tunnel.*xrun" | wc -l || echo "0")
            xrun_count=$((xrun_count + pipewire_xruns))
        fi
    fi

    # JACK direct xruns (if JACK is running)
    if pgrep -x "jackd\|jackdbus" > /dev/null 2>&1; then
        # JACK server messages from last 15 seconds
        if command -v journalctl &> /dev/null; then
            local jack_recent
            jack_recent=$(journalctl --since "15 seconds ago" --no-pager -q 2>/dev/null | grep -iE "jack.*(xrun|buffer.*late|delay.*exceeded|timeout)" | wc -l || echo "0")
            xrun_count=$((xrun_count + jack_recent))
        fi

        # QJackCtl/Patchance specific logs
        if pgrep -x "qjackctl" > /dev/null 2>&1; then
            local qjackctl_live
            qjackctl_live=$(journalctl --since "15 seconds ago" --no-pager -q 2>/dev/null | grep -iE "(qjackctl|patchance).*(xrun|late|timeout)" | wc -l || echo "0")
            xrun_count=$((xrun_count + qjackctl_live))
        fi
    fi

    echo "$xrun_count"
}

# ============================================================================
# SYSTEM XRUN MONITORING
# ============================================================================
#
# System-wide monitoring looks at broader indicators including
# USB errors and hardware problems that may cause audio issues.

# Get system-wide xrun information from logs and messages
# Searches journalctl and dmesg for audio-related problems.
#
# Returns: "recent:N|severe:N|jack_msg:N" (pipe-separated string)
#   - recent: Audio xruns in last 5 minutes
#   - severe: Hardware errors (USB disconnects, resets, etc.)
#   - jack_msg: JACK-specific messages
get_system_xruns() {
    local recent_xruns=0
    local severe_xruns=0
    local jack_messages=0

    # Search in last 5 minutes for audio xruns
    if command -v journalctl &> /dev/null; then
        # JACK-specific messages
        jack_messages=$(journalctl --since "5 minutes ago" -u "*jack*" 2>/dev/null | grep -i "xrun\|delay\|timeout" | wc -l || echo "0")

        # General audio problems
        recent_xruns=$(journalctl --since "5 minutes ago" 2>/dev/null | grep -iE "(audio|sound).*(xrun|underrun|overrun|drop|timeout|delay)" | wc -l || echo "0")

        # Hardware errors - only count actual critical issues, not routine resets
        # Exclude common non-critical messages like "reset high-speed USB device"
        severe_xruns=$(journalctl --since "5 minutes ago" 2>/dev/null | \
            grep -iE "(usb|audio|snd).*(error|fail|disconnect|timeout|cannot)" | \
            grep -viE "reset.*device|device descriptor|enabled|configured" | \
            wc -l || echo "0")
    fi

    # Dmesg for USB audio problems (with sudo fallback)
    if command -v dmesg &> /dev/null; then
        local usb_audio_errors
        usb_audio_errors=$(dmesg 2>/dev/null | tail -100 | grep -iE "(usb|audio).*(error|xrun|underrun)" | wc -l 2>/dev/null || echo "0")
        if [ "$usb_audio_errors" = "0" ] && [ "$EUID" -eq 0 ]; then
            usb_audio_errors=$(dmesg | tail -100 | grep -iE "(usb|audio).*(error|xrun|underrun)" | wc -l 2>/dev/null || echo "0")
        fi
        severe_xruns=$((severe_xruns + usb_audio_errors))
    fi

    echo "recent:$recent_xruns|severe:$severe_xruns|jack_msg:$jack_messages"
}

# ============================================================================
# XRUN ANALYSIS HELPERS
# ============================================================================
#
# Helper functions for parsing and analyzing xrun statistics.

# Parse xrun stats string and extract specific value
# Extracts a named field from the pipe-separated stats string.
#
# Args:
#   $1 - Stats string (e.g., "jack:5|pipewire:3|total:8")
#   $2 - Field name to extract ("jack", "pipewire", or "total")
#
# Returns: The numeric value for the specified field
parse_xrun_stats() {
    local stats="$1"
    local field="$2"

    echo "$stats" | tr '|' '\n' | grep "^$field:" | cut -d':' -f2
}

# Parse system xruns string and extract specific value
# Args: $1 = stats string, $2 = field name (recent, severe, jack_msg)
parse_system_xruns() {
    local stats="$1"
    local field="$2"

    echo "$stats" | tr '|' '\n' | grep "^$field:" | cut -d':' -f2
}

# Determine xrun severity level
# Categorizes xrun situation for appropriate recommendations.
#
# Args:
#   $1 - Total xrun count
#   $2 - Severe (hardware error) xrun count (optional, default 0)
#
# Returns: "perfect" (0 xruns), "mild" (<5 xruns), or "severe" (>=5 or hardware errors)
get_xrun_severity() {
    local total_xruns="$1"
    local severe_xruns="${2:-0}"

    if [ "$total_xruns" -eq 0 ] && [ "$severe_xruns" -eq 0 ]; then
        echo "perfect"
    elif [ "$total_xruns" -lt 5 ] && [ "$severe_xruns" -eq 0 ]; then
        echo "mild"
    else
        echo "severe"
    fi
}

# Get xrun status icon based on count
# Args: $1 = xrun count
get_xrun_icon() {
    local xrun_count="$1"

    if [ "$xrun_count" -eq 0 ]; then
        echo "✅"
    elif [ "$xrun_count" -lt 5 ]; then
        echo "⚠️"
    else
        echo "❌"
    fi
}

# ============================================================================
# XRUN RATE TRACKING
# ============================================================================
#
# Rate calculation helps determine if audio problems are getting
# worse or improving over time.

# Calculate xrun rate (xruns per minute)
# Normalizes xrun count to a per-minute rate for comparison.
#
# Args:
#   $1 - Xrun count observed
#   $2 - Time period in seconds over which xruns were counted
#
# Returns: Xruns per minute (e.g., "12.5" or "12")
calculate_xrun_rate() {
    local xrun_count="$1"
    local time_period="$2"

    if [ "$time_period" -eq 0 ]; then
        echo "0"
        return
    fi

    # Calculate rate per minute
    if command -v bc &> /dev/null; then
        echo "scale=1; $xrun_count * 60 / $time_period" | bc -l 2>/dev/null || echo "$((xrun_count * 60 / time_period))"
    else
        echo "$((xrun_count * 60 / time_period))"
    fi
}

# Get latest xrun log message
# Returns: Latest xrun message from journalctl or empty string
get_latest_xrun_message() {
    if command -v journalctl &> /dev/null; then
        journalctl --since "5 seconds ago" --no-pager -q 2>/dev/null | \
            grep -i "mod\.jack-tunnel.*xrun\|jack.*xrun" | \
            tail -1 | \
            cut -d' ' -f5-
    fi
}
