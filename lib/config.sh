#!/bin/bash

# Realtime Audio Optimizer - Configuration Module
# Contains all configuration variables and constants
#
# ============================================================================
# MODULE API REFERENCE
# ============================================================================
#
# This module provides configuration constants only (no functions).
# All values should be treated as read-only after module load.
#
# EXPORTED VARIABLES:
#
#   File Paths:
#     LOG_FILE            : string  - System log file path
#     STATE_FILE          : string  - Runtime state file path
#
#   CPU Assignments:
#     IRQ_CPUS            : string  - CPU range for IRQ handling (e.g., "14-19")
#     AUDIO_MAIN_CPUS     : string  - CPU range for JACK/PipeWire (e.g., "6-7")
#     DAW_CPUS            : string  - CPU range for DAW applications (e.g., "0-5")
#     BACKGROUND_CPUS     : string  - CPU range for background tasks (e.g., "8-13")
#     ALL_CPUS            : string  - Full CPU range for reset (e.g., "0-19")
#
#   Default Settings:
#     DEFAULT_GOVERNOR    : string  - Default CPU governor (e.g., "powersave")
#
#   Audio Interface Detection:
#     AUTO_DETECT_USB_AUDIO : bool  - Enable automatic USB audio detection
#
#   Xrun Thresholds:
#     XRUN_WARNING_THRESHOLD : int  - Xruns/30s before warning (default: 10)
#     XRUN_SEVERE_THRESHOLD  : int  - Xruns/30s for severe status (default: 5)
#
#   Timing Constants:
#     MONITOR_INTERVAL       : int  - Main loop interval in seconds (default: 5)
#     PROCESS_CHECK_INTERVAL : int  - Process check interval in seconds (default: 30)
#     XRUN_CHECK_INTERVAL    : int  - Xrun check interval in seconds (default: 10)
#     MAX_AUDIO_WAIT         : int  - Max wait for audio services in seconds (default: 45)
#
#   Audio Process Configuration:
#     AUDIO_PROCESSES     : array   - List of audio process names to optimize
#     AUDIO_GREP_PATTERN  : string  - Regex pattern for finding audio processes
#
#   RT Priority Levels:
#     RT_PRIORITY_JACK    : int     - JACK server priority (default: 99)
#     RT_PRIORITY_PIPEWIRE: int     - PipeWire priority (default: 85)
#     RT_PRIORITY_PULSE   : int     - PipeWire-Pulse priority (default: 80)
#     RT_PRIORITY_AUDIO   : int     - Audio applications priority (default: 70)
#
#   Version Information:
#     OPTIMIZER_VERSION   : string  - Version number (e.g., "1.0")
#     OPTIMIZER_NAME      : string  - Full product name
#     OPTIMIZER_STRATEGY  : string  - Strategy description
#
# DEPENDENCIES: None (pure configuration)
#
# ============================================================================
# FILE PATHS
# ============================================================================

# shellcheck disable=SC2034  # Variables are used by other sourced modules
LOG_FILE="/var/log/realtime-audio-optimizer.log"
STATE_FILE="/var/run/rt-audio-state"

# ============================================================================
# CPU ASSIGNMENTS
# ============================================================================
#
# CPU topology for Intel 12th/13th Gen hybrid architecture:
#   - P-Cores (Performance): CPUs 0-7 - High single-thread performance
#   - E-Cores (Efficiency): CPUs 8-19 - Lower power, good for background tasks
#
# Assignment strategy:
#   - Audio-critical processes (JACK, DAWs) run on P-Cores for lowest latency
#   - IRQ handling on dedicated E-Cores to avoid interrupting audio processing
#   - Background tasks on remaining E-Cores to reduce interference
#
# Note: Adjust these values if your CPU has a different core layout

IRQ_CPUS="14-19"        # E-Cores for IRQ handling (stable latency)
AUDIO_MAIN_CPUS="6-7"   # P-Cores for JACK/PipeWire main processes
DAW_CPUS="0-5"          # P-Cores for DAW/Plugins (maximum performance)
BACKGROUND_CPUS="8-13"  # E-Cores for audio background tasks

# All CPUs range (for reset operations)
ALL_CPUS="0-19"

# ============================================================================
# DEFAULT SETTINGS
# ============================================================================

DEFAULT_GOVERNOR="powersave"

# ============================================================================
# AUDIO INTERFACE DETECTION
# ============================================================================
#
# When AUTO_DETECT_USB_AUDIO is true, the optimizer will automatically
# detect and optimize ALL connected USB audio interfaces.
# This works with any USB Audio Class compliant device.

AUTO_DETECT_USB_AUDIO=true

# ============================================================================
# XRUN MONITORING THRESHOLDS
# ============================================================================
#
# Xruns (buffer underruns/overruns) indicate audio dropouts.
# These thresholds determine when warnings are triggered during monitoring.
#   - WARNING: Occasional xruns, audio still usable but consider buffer increase
#   - SEVERE: Frequent xruns, audio quality significantly degraded

XRUN_WARNING_THRESHOLD=10  # Xruns per 30s before warning is shown
XRUN_SEVERE_THRESHOLD=5    # Xruns per 30s considered severe (with other issues)

# ============================================================================
# TIMING CONSTANTS
# ============================================================================
#
# Intervals control how often the optimizer checks and adjusts settings.
# Lower values = more responsive but higher CPU overhead
# Higher values = less overhead but slower reaction to changes

# Monitoring intervals (in seconds)
MONITOR_INTERVAL=5         # Main loop sleep between checks
PROCESS_CHECK_INTERVAL=30  # Check process affinity every 30 seconds (6 cycles)
XRUN_CHECK_INTERVAL=10     # Check xruns every 10 seconds (2 cycles)

# Delayed service timing
# When started as system service, wait for user session audio services to appear
MAX_AUDIO_WAIT=45          # Maximum wait time for user audio services (PipeWire/JACK)

# ============================================================================
# AUDIO PROCESSES LIST
# ============================================================================

# Unified audio process list for all optimizations
# This central list is used by all audio optimization functions:
# - optimize_audio_process_affinity() for CPU pinning and RT priorities
# - reset_audio_process_affinity() for resetting optimizations
# - Status-Monitoring for process overview

AUDIO_PROCESSES=(
    # Audio engines and services (handled separately on AUDIO_MAIN_CPUS)
    "jackd"
    "jackdbus"
    "pipewire"
    "pipewire-pulse"
    "wireplumber"

    # DAWs and main audio software (DAW_CPUS + RT priority 70)
    "bitwig-studio"
    "reaper"
    "ardour"
    "studio"
    "cubase"
    "qtractor"
    "rosegarden"
    "renoise"
    "FL64.exe"
    "EZmix 3.exe"

    # Synthesizers and sound generators (DAW_CPUS + RT priority 70)
    "yoshimi"
    "pianoteq"
    "organteq"
    "grandorgue"
    "aeolus"
    "zynaddsubfx"
    "qsynth"
    "fluidsynth"
    "bristol"
    "M1.exe"
    "ARP 2600"
    "Polisix.exe"
    "EP-1.exe"
    "VOX Super Conti"
    "legacycell.exe"
    "wavestate nativ"
    "WAVESTATION.exe"
    "opsix_native.ex"
    "modwave native."
    "ARP ODYSSEY"
    "TRITON.exe"
    "TRITON_Extreme."
    "EZkeys 2.exe"
    "EZbass.exe"
    "AAS Player.exe"
    "Lounge Lizard S"

    # Drums and percussion (DAW_CPUS + RT priority 70)
    "hydrogen"
    "drumgizmo"
    "EZdrummer 3.exe"

    # Plugin hosts and audio tools (DAW_CPUS + RT priority 70)
    "carla"
    "jalv"
    "lv2host"
    "lv2rack"
    "jack-rack"
    "calf"
    "guitarix"
    "rakarrack"
    "klangfalter"

    # Audio editors (DAW_CPUS + RT priority 70)
    "musescore"
    "audacity"
)

# ============================================================================
# RT PRIORITY LEVELS
# ============================================================================
#
# Real-time (SCHED_FIFO) priorities for audio processes.
# Range: 1-99, higher = more priority (will preempt lower priority tasks)
#
# Priority hierarchy (highest to lowest):
#   99 - JACK server: Must never be interrupted, handles all audio I/O
#   85 - PipeWire: Audio graph processing
#   80 - PipeWire-Pulse: PulseAudio compatibility layer
#   70 - Audio apps: DAWs, synths, plugins - below audio servers
#
# Note: Requires appropriate RT permissions (rtkit or limits.conf)

RT_PRIORITY_JACK=99       # Highest for JACK server
RT_PRIORITY_PIPEWIRE=85   # High for PipeWire
RT_PRIORITY_PULSE=80      # PipeWire-Pulse
RT_PRIORITY_AUDIO=70      # DAWs, synths, plugins

# ============================================================================
# GREP PATTERNS FOR AUDIO PROCESSES
# ============================================================================

# Pattern for finding RT audio processes in ps output
AUDIO_GREP_PATTERN="pulse|pipe|jack|audio|pianoteq|organteq|reaper|ardour|bitwig|kontakt|logic|ableton|fl_studio|studio|daw|yoshimi|grandorgue|renoise|carla|jalv|qtractor|rosegarden|musescore|zynaddsubfx|qsynth|fluidsynth|bristol|hydrogen|drumgizmo|guitarix|rakarrack"

# ============================================================================
# LOGGING CONFIGURATION
# ============================================================================
#
# Log levels control verbosity of output:
#   DEBUG - All messages, including internal state (verbose)
#   INFO  - Normal operation messages (default)
#   WARN  - Warnings and errors only
#   ERROR - Only critical errors
#
# Set via environment variable RT_AUDIO_LOG_LEVEL or in config file

RT_AUDIO_LOG_LEVEL="${RT_AUDIO_LOG_LEVEL:-INFO}"
# Legacy support
MOTU_LOG_LEVEL="${RT_AUDIO_LOG_LEVEL}"

# ============================================================================
# SYSTEM TRAY CONFIGURATION
# ============================================================================
#
# Optional system tray icon for visual status display.
# Requires yad package or PyQt5 to be installed.

# Enable/disable the system tray integration
# Set to "true" to enable tray state updates
TRAY_ENABLED="${TRAY_ENABLED:-false}"

# Path to the tray state file (read by tray application)
TRAY_STATE_FILE="/var/run/rt-audio-tray-state"

# Tray icon directory (where icons are installed)
TRAY_ICON_DIR="/usr/share/icons/realtime-audio"

# Tray update interval in seconds (how often tray polls state file)
TRAY_UPDATE_INTERVAL="${TRAY_UPDATE_INTERVAL:-5}"

# Show desktop notification on xruns
TRAY_NOTIFY_ON_XRUN="${TRAY_NOTIFY_ON_XRUN:-true}"

# Show desktop notification on state changes (connect/disconnect)
TRAY_NOTIFY_ON_STATE_CHANGE="${TRAY_NOTIFY_ON_STATE_CHANGE:-true}"

# ============================================================================
# VERSION INFO
# ============================================================================

OPTIMIZER_VERSION="1.0"
OPTIMIZER_NAME="Realtime Audio Optimizer"
OPTIMIZER_STRATEGY="Hybrid Strategy (Stability-optimized)"

# ============================================================================
# EXTERNAL CONFIGURATION FILE SUPPORT
# ============================================================================
#
# Users can override default values by creating /etc/realtime-audio-optimizer.conf
# Only defined variables in the config file will override defaults.
#
# See /etc/realtime-audio-optimizer.conf.example for available options.

CONFIG_FILE="/etc/realtime-audio-optimizer.conf"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Handle EXTRA_AUDIO_PROCESSES if defined
    if [ -n "${EXTRA_AUDIO_PROCESSES:-}" ]; then
        # Convert space-separated string to array and append to AUDIO_PROCESSES
        read -ra EXTRA_ARRAY <<< "$EXTRA_AUDIO_PROCESSES"
        AUDIO_PROCESSES+=("${EXTRA_ARRAY[@]}")
    fi
fi
