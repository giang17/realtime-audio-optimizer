#!/bin/bash

# Realtime Audio Optimizer - Logging Module
# Provides structured logging with log levels and fallback for non-root users
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# PUBLIC FUNCTIONS:
#
#   log_debug(message)
#     Logs a DEBUG level message (only if LOG_LEVEL includes DEBUG).
#     @param  message : string - The message to log
#     @return         : void
#     @stdout         : Timestamped message with [DEBUG] prefix (if level enabled)
#     @file           : Appends to LOG_FILE (root) or user log (non-root)
#
#   log_info(message)
#     Logs an INFO level message (default level).
#     @param  message : string - The message to log
#     @return         : void
#     @stdout         : Timestamped message with [INFO] prefix
#     @file           : Appends to LOG_FILE (root) or user log (non-root)
#
#   log_warn(message)
#     Logs a WARN level message for non-critical issues.
#     @param  message : string - The message to log
#     @return         : void
#     @stdout         : Timestamped message with [WARN] prefix
#     @file           : Appends to LOG_FILE (root) or user log (non-root)
#
#   log_error(message)
#     Logs an ERROR level message for critical issues.
#     @param  message : string - The message to log
#     @return         : void
#     @stderr         : Timestamped message with [ERROR] prefix
#     @file           : Appends to LOG_FILE (root) or user log (non-root)
#
#   log_message(message)
#     Legacy function - maps to log_info() for backwards compatibility.
#     @deprecated     : Use log_info(), log_warn(), log_error(), or log_debug()
#
#   log_silent(message)
#     Logs silently to file only (no stdout output). Maps to DEBUG level.
#     @param  message : string - The message to log
#     @return         : void
#     @stdout         : (none)
#     @file           : Appends to LOG_FILE if writable, otherwise discards
#
# DEPENDENCIES:
#   - config.sh (LOG_FILE variable)
#
# ENVIRONMENT VARIABLES:
#   - RT_AUDIO_LOG_LEVEL  : Set log level (DEBUG, INFO, WARN, ERROR). Default: INFO
#   - RT_AUDIO_QUIET_LOG  : If "1", skips file logging in log functions
#
# ============================================================================

# Log level constants (lower number = more verbose)
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Current log level (default: INFO)
# Can be overridden via RT_AUDIO_LOG_LEVEL environment variable
_get_log_level() {
    local log_level="${RT_AUDIO_LOG_LEVEL:-${MOTU_LOG_LEVEL:-INFO}}"
    case "$log_level" in
        DEBUG|debug) echo "$LOG_LEVEL_DEBUG" ;;
        INFO|info)   echo "$LOG_LEVEL_INFO" ;;
        WARN|warn)   echo "$LOG_LEVEL_WARN" ;;
        ERROR|error) echo "$LOG_LEVEL_ERROR" ;;
        *)           echo "$LOG_LEVEL_INFO" ;;
    esac
}

# Internal: Check if a log level should be output
# Args:
#   $1 - Log level to check (numeric)
# Returns:
#   0 if level should be logged, 1 otherwise
_should_log() {
    local level="$1"
    local current_level
    current_level=$(_get_log_level)
    [ "$level" -ge "$current_level" ]
}

# Internal: Core logging function with level support
# Args:
#   $1 - Log level (DEBUG, INFO, WARN, ERROR)
#   $2 - Message to log
#   $3 - Output stream (stdout or stderr, default: stdout)
_log_with_level() {
    local level="$1"
    local msg="$2"
    local stream="${3:-stdout}"
    local level_num
    local message

    # Convert level to number for comparison
    case "$level" in
        DEBUG) level_num=$LOG_LEVEL_DEBUG ;;
        INFO)  level_num=$LOG_LEVEL_INFO ;;
        WARN)  level_num=$LOG_LEVEL_WARN ;;
        ERROR) level_num=$LOG_LEVEL_ERROR ;;
        *)     level_num=$LOG_LEVEL_INFO ;;
    esac

    # Check if we should log at this level
    if ! _should_log "$level_num"; then
        return 0
    fi

    # Format message with timestamp and level
    message="$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg"

    # Try to write to system log (suppress errors completely)
    if [ -w "$LOG_FILE" ] 2>/dev/null && echo "$message" >> "$LOG_FILE" 2>/dev/null; then
        if [ "$stream" = "stderr" ]; then
            echo "$message" >&2
        else
            echo "$message"
        fi
    else
        # Fallback for normal users - silent mode for status commands
        local quiet_log="${RT_AUDIO_QUIET_LOG:-${MOTU_QUIET_LOG:-0}}"
        if [ "$quiet_log" = "1" ]; then
            # Just output without logging
            if [ "$stream" = "stderr" ]; then
                echo "$message" >&2
            else
                echo "$message"
            fi
        else
            local user_log="$HOME/.local/share/realtime-audio-optimizer.log"
            mkdir -p "$(dirname "$user_log")" 2>/dev/null
            if [ "$stream" = "stderr" ]; then
                echo "$message" | tee -a "$user_log" >&2 2>/dev/null
            else
                echo "$message" | tee -a "$user_log" 2>/dev/null
            fi

            # One-time warning about log location
            if [ ! -f "$HOME/.local/share/.rt-audio-log-warning-shown" ] 2>/dev/null; then
                echo "Log is saved to: $user_log" >&2
                touch "$HOME/.local/share/.rt-audio-log-warning-shown" 2>/dev/null
            fi
        fi
    fi
}

# ============================================================================
# PUBLIC LOGGING FUNCTIONS
# ============================================================================

# Log a DEBUG message (verbose, for troubleshooting)
# Only shown when RT_AUDIO_LOG_LEVEL=DEBUG
#
# Example:
#   log_debug "Checking CPU isolation status"
log_debug() {
    _log_with_level "DEBUG" "$1" "stdout"
}

# Log an INFO message (normal operations)
# Default level, always shown unless RT_AUDIO_LOG_LEVEL is WARN or ERROR
#
# Example:
#   log_info "Audio interface detected - Activating optimizations"
log_info() {
    _log_with_level "INFO" "$1" "stdout"
}

# Log a WARN message (non-critical issues)
# Shown unless RT_AUDIO_LOG_LEVEL is ERROR only
#
# Example:
#   log_warn "Xrun detected: 5 xruns in last 30s"
log_warn() {
    _log_with_level "WARN" "$1" "stdout"
}

# Log an ERROR message (critical issues)
# Always shown regardless of RT_AUDIO_LOG_LEVEL
#
# Example:
#   log_error "Failed to set CPU governor"
log_error() {
    _log_with_level "ERROR" "$1" "stderr"
}

# Legacy function for backwards compatibility
# Maps to log_info() - use specific level functions for new code
#
# @deprecated Use log_info(), log_warn(), log_error(), or log_debug() instead
#
# Example:
#   log_message "Starting optimization..."  # Use log_info() instead
log_message() {
    log_info "$1"
}

# Silent log - only logs if we have permission, otherwise discards
# Use this for debug/verbose messages that shouldn't clutter stdout.
#
# Behavior:
#   - Writes to system log only if writable (running as root)
#   - Silently discards message if no write permission
#   - Never outputs to stdout
#
# Args:
#   $1 - Message to log
#
# Example:
#   log_silent "Debug: CPU isolation check completed"
log_silent() {
    local message
    message="$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1"

    if [ -w "$LOG_FILE" ] 2>/dev/null; then
        echo "$message" >> "$LOG_FILE" 2>/dev/null
    fi
}
