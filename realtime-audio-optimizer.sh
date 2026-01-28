#!/bin/bash

# Realtime Audio Optimizer v1.0 - Hybrid Strategy (Stability-optimized)
# P-Cores on Performance, Background E-Cores on Powersave, IRQ E-Cores on Performance
#
# This is the main entry point script that loads modular components from lib/
#
# Usage: realtime-audio-optimizer.sh [command]
#
# Commands:
#   monitor     - Continuous monitoring (default)
#   once        - One-time optimization
#   status      - Standard status display
#   detailed    - Detailed hardware monitoring
#   live-xruns  - Live xrun monitoring (real-time)
#   detect      - Detect connected audio interfaces
#   stop        - Deactivate optimizations

# Note: Do NOT use "set -e" here - many operations may fail non-critically
# (e.g., IRQ threading not supported, some kernel params not available)

# ============================================================================
# SCRIPT INITIALIZATION
# ============================================================================

# Determine script directory (works with symlinks too)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ============================================================================
# MODULE LOADING
# ============================================================================

# Check if lib directory exists
if [ ! -d "$LIB_DIR" ]; then
    echo "Error: Library directory not found: $LIB_DIR"
    echo "   Please ensure all module files are in the lib/ subdirectory."
    exit 1
fi

# List of required modules in load order (dependencies first)
REQUIRED_MODULES=(
    "config.sh"       # Configuration variables (must be first)
    "logging.sh"      # Logging functions
    "interfaces.sh"   # Audio interface detection (NEW)
    "checks.sh"       # System detection functions
    "jack.sh"         # JACK-related functions
    "xrun.sh"         # Xrun monitoring functions
    "process.sh"      # Process affinity management
    "usb.sh"          # USB optimization functions
    "kernel.sh"       # Kernel parameter optimization
    "optimization.sh" # Main optimization functions
    "status.sh"       # Status display functions
    "monitor.sh"      # Monitoring loops
)

# Load all modules
for module in "${REQUIRED_MODULES[@]}"; do
    module_path="$LIB_DIR/$module"
    if [ -f "$module_path" ]; then
        # shellcheck source=/dev/null
        source "$module_path"
    else
        echo "Error: Required module not found: $module_path"
        exit 1
    fi
done

# ============================================================================
# HELP / USAGE
# ============================================================================

show_help() {
    echo "$OPTIMIZER_NAME v$OPTIMIZER_VERSION - $OPTIMIZER_STRATEGY"
    echo ""
    echo "Usage: $0 [monitor|once|status|detailed|live-xruns|detect|stop]"
    echo ""
    echo "Commands:"
    echo "  monitor     - Continuous monitoring (default)"
    echo "  once        - One-time optimization"
    echo "  status      - Standard status display"
    echo "  detailed    - Detailed hardware monitoring"
    echo "  live-xruns  - Live xrun monitoring (real-time)"
    echo "  detect      - Detect connected USB audio interfaces"
    echo "  stop        - Deactivate optimizations"
    echo ""
    echo "CPU Strategy (Hybrid for Stability):"
    echo "  P-Cores 0-7:        Performance (Audio-Processing)"
    echo "  E-Cores 8-13:       Powersave (Background, less interference)"
    echo "  E-Cores 14-19:      Performance (IRQ-Handling)"
    echo ""
    echo "Process pinning:"
    echo "  P-Cores 0-5: DAW/Plugins (maximum single-thread performance)"
    echo "  P-Cores 6-7: JACK/PipeWire (dedicated audio engine)"
    echo "  E-Cores 8-13: Background-Tasks"
    echo "  E-Cores 14-19: IRQ handling (stable latency)"
    echo ""
    echo "Supported interfaces: All USB Audio Class compliant devices"
}

# ============================================================================
# DETECT COMMAND
# ============================================================================

show_detected_interfaces() {
    echo "$OPTIMIZER_NAME v$OPTIMIZER_VERSION"
    echo ""
    echo "Detecting USB audio interfaces..."
    echo ""

    local interfaces
    interfaces=$(detect_usb_audio_interfaces)

    if [ -z "$interfaces" ]; then
        echo "No USB audio interfaces found."
        echo ""
        echo "Make sure your audio interface is:"
        echo "  - Connected via USB"
        echo "  - Powered on"
        echo "  - Recognized by the system (check 'lsusb')"
        return 1
    fi

    echo "Detected interfaces:"
    echo ""

    local count=0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        count=$((count + 1))

        # Parse entry: card_name|alsa_id|usb_path|vendor:product|friendly_name
        local card_name=$(echo "$entry" | cut -d'|' -f1)
        local alsa_id=$(echo "$entry" | cut -d'|' -f2)
        local usb_path=$(echo "$entry" | cut -d'|' -f3)
        local vendor_product=$(echo "$entry" | cut -d'|' -f4)
        local friendly_name=$(echo "$entry" | cut -d'|' -f5)

        echo "  [$count] $friendly_name"
        echo "      ALSA Card: $card_name (ID: $alsa_id)"
        echo "      USB Path:  $usb_path"
        echo "      USB ID:    $vendor_product"
        echo ""
    done <<< "$interfaces"

    echo "Total: $count interface(s) found"
    echo ""
    echo "Run 'sudo $0 once' to activate optimizations."
}

# ============================================================================
# MAIN COMMAND HANDLER
# ============================================================================

case "${1:-monitor}" in
    "monitor"|"daemon")
        main_monitoring_loop
        ;;

    "live-xruns"|"xrun-monitor")
        live_xrun_monitoring
        ;;

    "once"|"run")
        interface_connected=$(check_audio_interfaces)
        if [ "$interface_connected" = "true" ]; then
            log_info "One-time activation of Hybrid Audio Optimizations"
            activate_audio_optimizations
        else
            log_info "No audio interface detected - Deactivating optimizations"
            deactivate_audio_optimizations
        fi
        ;;

    "once-delayed")
        delayed_service_start
        ;;

    "status")
        show_status
        ;;

    "detailed"|"detail"|"monitor-detail")
        show_detailed_status
        ;;

    "detect"|"list"|"interfaces")
        show_detected_interfaces
        ;;

    "stop"|"reset")
        log_info "Manual reset requested"
        deactivate_audio_optimizations
        ;;

    "help"|"-h"|"--help")
        show_help
        exit 0
        ;;

    *)
        show_help
        exit 1
        ;;
esac
