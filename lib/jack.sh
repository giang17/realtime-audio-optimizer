#!/bin/bash

# Realtime Audio Optimizer - JACK Module
# Contains JACK-related functions for settings retrieval and recommendations
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   get_jack_settings()
#     Queries JACK server for current configuration.
#     @return : string - "status|bufsize|samplerate|nperiods"
#     @stdout : Pipe-separated settings string
#     @note   : Handles both JACK and PipeWire-JACK
#
#   calculate_latency_ms(bufsize, samplerate)
#     Calculates audio latency from buffer settings.
#     @param  bufsize    : int|string - Buffer size in samples or "unknown"
#     @param  samplerate : int|string - Sample rate in Hz or "unknown"
#     @return            : string - Latency in ms (e.g., "5.3") or "unknown"
#     @stdout            : Latency value
#
#   get_dynamic_xrun_recommendations(xrun_count, severity)
#     Generates context-aware buffer recommendations.
#     @param  xrun_count : int - Number of xruns observed
#     @param  severity   : string - "perfect", "mild", or "severe"
#     @return            : void
#     @stdout            : Multi-line recommendations
#
#   get_recommended_buffer(current_buffer, xrun_count)
#     Calculates recommended buffer size based on xruns.
#     @param  current_buffer : int|string - Current buffer size or "unknown"
#     @param  xrun_count     : int - Number of xruns observed
#     @return                : int - Recommended buffer size in samples
#     @stdout                : Buffer size value
#
#   is_jack_running()
#     Checks if JACK audio server is running.
#     @exit   : 0 if running, 1 if not
#     @note   : Duplicated from checks.sh for module independence
#
#   get_jack_compact_info()
#     Gets compact JACK status for display.
#     @return : string - "256@48000Hz" or "Inactive"
#     @stdout : Compact status string
#
# RETURN VALUE FORMATS:
#
#   get_jack_settings() returns:
#     "status|bufsize|samplerate|nperiods"
#     - status: "Active", "Running (interface not available)",
#               "Active (user session)", or "Not active"
#     - bufsize: Buffer size in samples (e.g., "256") or "unknown"
#     - samplerate: Sample rate in Hz (e.g., "48000") or "unknown"
#     - nperiods: Number of periods (e.g., "2") or "unknown"
#
# DEPENDENCIES:
#   - External commands: jack_bufsize, jack_samplerate, jack_control (optional)
#   - Optional: bc (for precise latency calculation)
#
# ============================================================================
# JACK SETTINGS RETRIEVAL
# ============================================================================
#
# JACK (Jack Audio Connection Kit) settings are critical for audio latency.
# Key parameters:
#   - Buffer size: Samples per period (lower = less latency, more CPU)
#   - Sample rate: Audio sample rate in Hz (higher = better quality, more CPU)
#   - Periods: Number of buffers (2-3 typical, more = more latency tolerance)

# Get current JACK settings
# Queries running JACK server for its configuration.
# Handles both direct JACK and PipeWire's JACK compatibility layer.
#
# Returns: "status|bufsize|samplerate|nperiods" (pipe-separated string)
#   - status: "Active", "Running (interface not available)", or "Not active"
#   - bufsize: Buffer size in samples or "unknown"
#   - samplerate: Sample rate in Hz or "unknown"
#   - nperiods: Number of periods or "unknown"
#
# Example: "Active|256|48000|2"
get_jack_settings() {
    local bufsize="unknown"
    local samplerate="unknown"
    local nperiods="unknown"
    local jack_status="Not active"

    # Determine the original user if script runs as root via sudo
    local original_user=""
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        original_user="$SUDO_USER"
    elif [ "$EUID" -ne 0 ]; then
        original_user="$(whoami)"
    fi

    # Check if JACK is running AND audio interface is available
    if pgrep -x "jackd" > /dev/null 2>&1 || pgrep -x "jackdbus" > /dev/null 2>&1; then
        # JACK process running, but also check if any USB audio interface is available
        local interface_available="false"
        if is_audio_interface_connected 2>/dev/null; then
            interface_available="true"
        fi

        if [ "$interface_available" = "true" ]; then
            jack_status="Active"
        else
            jack_status="Running (interface not available)"
        fi

        # Function to execute JACK commands in user context
        run_jack_command() {
            local cmd="$1"
            if [ -n "$original_user" ] && [ "$EUID" -eq 0 ]; then
                # As root: Use sudo -u to run in user context
                sudo -u "$original_user" "$cmd" 2>/dev/null || echo "unknown"
            else
                # As normal user: Execute directly
                "$cmd" 2>/dev/null || echo "unknown"
            fi
        }

        # Try to determine JACK parameters
        if command -v jack_bufsize &> /dev/null; then
            bufsize=$(run_jack_command "jack_bufsize")
        fi

        if command -v jack_samplerate &> /dev/null; then
            samplerate=$(run_jack_command "jack_samplerate")
        fi

        if command -v jack_control &> /dev/null; then
            # Extract nperiods value from format "uint:set:2:3" - take the last value
            if [ -n "$original_user" ] && [ "$EUID" -eq 0 ]; then
                nperiods=$(sudo -u "$original_user" jack_control dp 2>/dev/null | grep nperiods | awk -F':' '{print $NF}' | tr -d ')' || echo "unknown")
            else
                nperiods=$(jack_control dp 2>/dev/null | grep nperiods | awk -F':' '{print $NF}' | tr -d ')' || echo "unknown")
            fi
        fi

        # Fallback: If all JACK commands fail, but process runs
        if [ "$bufsize" = "unknown" ] && [ "$samplerate" = "unknown" ] && [ -n "$original_user" ]; then
            if [ "$jack_status" = "Active" ]; then
                jack_status="Active (user session)"
            fi
        fi
    fi

    echo "$jack_status|$bufsize|$samplerate|$nperiods"
}

# ============================================================================
# JACK LATENCY CALCULATIONS
# ============================================================================
#
# Audio latency formula: latency_ms = (buffer_size / sample_rate) * 1000
# Example: 256 samples @ 48000 Hz = 5.33ms per period
#
# Total round-trip latency = periods * buffer_latency * 2 (input + output)

# Calculate latency in milliseconds from buffer size and sample rate
# Uses bc for precise calculation, falls back to integer math if unavailable.
#
# Args:
#   $1 - Buffer size in samples
#   $2 - Sample rate in Hz
#
# Returns: Latency in milliseconds (e.g., "5.3" or "~5")
calculate_latency_ms() {
    local bufsize="$1"
    local samplerate="$2"

    if [ "$bufsize" = "unknown" ] || [ "$samplerate" = "unknown" ]; then
        echo "unknown"
        return
    fi

    if command -v bc &> /dev/null; then
        echo "scale=1; $bufsize * 1000 / $samplerate" | bc -l 2>/dev/null || echo "~$(($bufsize * 1000 / $samplerate))"
    else
        echo "~$(($bufsize * 1000 / $samplerate))"
    fi
}

# ============================================================================
# DYNAMIC XRUN RECOMMENDATIONS
# ============================================================================
#
# Xrun recommendations are generated based on current JACK settings and
# observed xrun counts. The recommendations suggest buffer size increases
# or other adjustments to reduce audio dropouts.

# Generate dynamic xrun recommendations based on current JACK settings
# Provides context-aware suggestions based on current configuration.
#
# Args:
#   $1 - Current xrun count
#   $2 - Severity level ("perfect", "mild", "severe")
#
# Output: Prints recommendations to stdout (not returned)
get_dynamic_xrun_recommendations() {
    local current_xruns=$1
    local severity=$2

    # Get current JACK settings
    local jack_info
    jack_info=$(get_jack_settings)
    local jack_status
    jack_status=$(echo "$jack_info" | cut -d'|' -f1)
    local bufsize
    bufsize=$(echo "$jack_info" | cut -d'|' -f2)
    local samplerate
    samplerate=$(echo "$jack_info" | cut -d'|' -f3)
    local nperiods
    nperiods=$(echo "$jack_info" | cut -d'|' -f4)

    # Format current settings for display
    local settings_info=""
    if [ "$jack_status" = "Active" ]; then
        settings_info="Current: ${bufsize}@${samplerate}Hz"
        if [ "$nperiods" != "unknown" ]; then
            settings_info="$settings_info, $nperiods periods"
        fi
    else
        settings_info="JACK not active"
    fi

    case "$severity" in
        "perfect")
            echo "   Perfect audio performance - No xruns!"
            echo "   $settings_info running optimally stable"
            ;;
        "mild")
            echo "   Occasional audio problems - Still within acceptable range"
            if [ "$jack_status" = "Active" ] && [ "$bufsize" != "unknown" ]; then
                # Dynamic recommendation based on current buffer
                if [ "$bufsize" -le 128 ]; then
                    echo "   For frequent problems: Increase buffer from $bufsize to 256 samples"
                elif [ "$bufsize" -le 256 ]; then
                    echo "   For frequent problems: Increase buffer from $bufsize to 512 samples"
                else
                    echo "   Buffer already high ($bufsize) - check CPU load or sample rate"
                fi

                # Periods recommendation
                if [ "$nperiods" != "unknown" ] && [ "$nperiods" -eq 2 ]; then
                    echo "   Consider using 3 periods instead of $nperiods for more stability"
                fi
            else
                echo "   $settings_info - Start JACK for specific recommendations"
            fi
            ;;
        "severe")
            echo "   Frequent audio problems detected ($current_xruns Xruns)"
            if [ "$jack_status" = "Active" ] && [ "$bufsize" != "unknown" ]; then
                # More aggressive recommendations for severe problems
                if [ "$bufsize" -le 64 ]; then
                    echo "   Immediate action: Increase buffer from $bufsize to 256+ samples"
                elif [ "$bufsize" -le 128 ]; then
                    echo "   Recommendation: Increase buffer from $bufsize to 512 samples"
                elif [ "$bufsize" -le 256 ]; then
                    echo "   Increase buffer from $bufsize to 1024 samples or higher"
                else
                    echo "   Buffer already very high ($bufsize) - system optimization needed"
                fi

                # Sample rate recommendation
                if [ "$samplerate" != "unknown" ] && [ "$samplerate" -gt 48000 ]; then
                    echo "   Or reduce sample rate from ${samplerate}Hz to 48kHz for more stability"
                fi

                # Periods recommendation
                if [ "$nperiods" != "unknown" ] && [ "$nperiods" -eq 2 ]; then
                    echo "   Important: Use 3 periods instead of $nperiods for better latency tolerance"
                fi
            else
                echo "   $settings_info - Start JACK for detailed recommendations"
                echo "   Generally: Higher buffer sizes (256+ samples) or lower sample rate"
            fi
            ;;
    esac
}

# ============================================================================
# BUFFER RECOMMENDATIONS
# ============================================================================
#
# Buffer size recommendations scale with the severity of xrun problems.
# General guidelines:
#   - No xruns: Current buffer is fine
#   - 1-5 xruns: Increase by 1.5x or to 256 minimum
#   - 5-20 xruns: Increase by 2x or to 512 minimum
#   - 20+ xruns: Increase by 4x or to 1024 minimum

# Get recommended buffer size based on xrun count
# Calculates appropriate buffer size increase based on xrun severity.
#
# Args:
#   $1 - Current buffer size in samples
#   $2 - Xrun count observed
#
# Returns: Recommended buffer size in samples
get_recommended_buffer() {
    local current_buffer="$1"
    local xrun_count="$2"

    if [ "$current_buffer" = "unknown" ]; then
        echo "256"  # Safe default
        return
    fi

    if [ "$xrun_count" -gt 20 ]; then
        # Severe problems - recommend 4x buffer or 1024 minimum
        local recommended=$((current_buffer * 4))
        [ "$recommended" -lt 1024 ] && recommended=1024
        echo "$recommended"
    elif [ "$xrun_count" -gt 5 ]; then
        # Moderate problems - recommend 2x buffer or 512 minimum
        local recommended=$((current_buffer * 2))
        [ "$recommended" -lt 512 ] && recommended=512
        echo "$recommended"
    elif [ "$xrun_count" -gt 0 ]; then
        # Minor problems - recommend 1.5x buffer or 256 minimum
        local recommended=$((current_buffer * 3 / 2))
        [ "$recommended" -lt 256 ] && recommended=256
        echo "$recommended"
    else
        # No problems - current buffer is fine
        echo "$current_buffer"
    fi
}

# ============================================================================
# JACK STATUS HELPERS
# ============================================================================
#
# Helper functions for JACK status checks and display formatting.

# Check if JACK is running
# Note: This is duplicated from checks.sh for module independence.
#
# Exit code: 0 if running, 1 if not
is_jack_running() {
    pgrep -x "jackd" > /dev/null 2>&1 || pgrep -x "jackdbus" > /dev/null 2>&1
}

# Get compact JACK info string for display
# Returns a short status string suitable for single-line display.
#
# Returns: "256@48000Hz" or "Inactive"
get_jack_compact_info() {
    local jack_info
    jack_info=$(get_jack_settings)
    local jack_status
    jack_status=$(echo "$jack_info" | cut -d'|' -f1)
    local bufsize
    bufsize=$(echo "$jack_info" | cut -d'|' -f2)
    local samplerate
    samplerate=$(echo "$jack_info" | cut -d'|' -f3)

    if [ "$jack_status" = "Active" ]; then
        echo "${bufsize}@${samplerate}Hz"
    else
        echo "Inactive"
    fi
}
