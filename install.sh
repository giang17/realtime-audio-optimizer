#!/bin/bash

# Realtime Audio Optimizer - Installer
# Handles installation, uninstallation, and updates
#
# Usage:
#   ./install.sh install    - Install the optimizer
#   ./install.sh uninstall  - Remove the optimizer
#   ./install.sh update     - Update existing installation
#   ./install.sh status     - Check installation status

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_NAME="realtime-audio-optimizer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths
INSTALL_BIN="/usr/local/bin"
INSTALL_LIB="/usr/local/lib/${SCRIPT_NAME}"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"
CONFIG_FILE="/etc/realtime-audio-optimizer.conf"
LOG_FILE="/var/log/realtime-audio-optimizer.log"

# Source files
MAIN_SCRIPT="${SCRIPT_DIR}/realtime-audio-optimizer.sh"
LIB_DIR="${SCRIPT_DIR}/lib"
SERVICE_FILE="${SCRIPT_DIR}/realtime-audio-optimizer.service"
DELAYED_SERVICE_FILE="${SCRIPT_DIR}/realtime-audio-optimizer-delayed.service"
UDEV_RULES="${SCRIPT_DIR}/99-realtime-audio-optimizer.rules"
EXAMPLE_CONFIG="${SCRIPT_DIR}/realtime-audio-optimizer.conf.example"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Realtime Audio Optimizer - Installer${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_step() {
    echo -e "${BLUE}➤ $1${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (sudo)"
        echo "   Please run: sudo $0 $1"
        exit 1
    fi
}

check_source_files() {
    local missing=0

    print_step "Checking source files..."

    if [ ! -f "$MAIN_SCRIPT" ]; then
        print_error "Main script not found: $MAIN_SCRIPT"
        missing=1
    fi

    if [ ! -d "$LIB_DIR" ]; then
        print_error "Library directory not found: $LIB_DIR"
        missing=1
    else
        # Check for required modules
        local required_modules=(
            "config.sh" "logging.sh" "interfaces.sh" "checks.sh" "jack.sh" "xrun.sh"
            "process.sh" "usb.sh" "kernel.sh" "optimization.sh"
            "status.sh" "monitor.sh"
        )
        for module in "${required_modules[@]}"; do
            if [ ! -f "${LIB_DIR}/${module}" ]; then
                print_error "Required module not found: lib/${module}"
                missing=1
            fi
        done
    fi

    if [ ! -f "$SERVICE_FILE" ]; then
        print_warning "Service file not found: $SERVICE_FILE (optional)"
    fi

    if [ ! -f "$UDEV_RULES" ]; then
        print_warning "Udev rules not found: $UDEV_RULES (optional)"
    fi

    if [ $missing -eq 1 ]; then
        print_error "Some required files are missing. Cannot continue."
        exit 1
    fi

    print_success "All required source files found"
}

# ============================================================================
# TRAY INSTALLATION
# ============================================================================

# Install tray components (optional - requires python3-pyqt5)
install_tray_components() {
    local tray_dir="${SCRIPT_DIR}/tray"

    # Check if tray directory exists
    if [ ! -d "$tray_dir" ]; then
        print_info "Tray directory not found - skipping tray installation"
        return 0
    fi

    # Check if PyQt5 is available (prefer Python version over yad)
    local use_python=false
    if python3 -c "from PyQt5.QtWidgets import QSystemTrayIcon" 2>/dev/null; then
        use_python=true
    elif ! command -v yad &> /dev/null; then
        print_warning "Neither python3-pyqt5 nor yad is installed - skipping tray components"
        print_info "To enable system tray, install: sudo apt install python3-pyqt5"
        return 0
    fi

    print_step "Installing system tray components..."

    # Install tray script (prefer Python version)
    if [ "$use_python" = true ] && [ -f "${tray_dir}/rt-audio-tray.py" ]; then
        install -m 755 "${tray_dir}/rt-audio-tray.py" "${INSTALL_BIN}/rt-audio-tray"
        print_success "Installed Python tray: ${INSTALL_BIN}/rt-audio-tray"
    elif [ -f "${tray_dir}/rt-audio-tray.sh" ]; then
        install -m 755 "${tray_dir}/rt-audio-tray.sh" "${INSTALL_BIN}/rt-audio-tray"
        print_success "Installed Bash tray: ${INSTALL_BIN}/rt-audio-tray"
    fi

    # Install icons
    if [ -d "${tray_dir}/icons" ]; then
        local icon_dest="/usr/share/icons/realtime-audio"
        mkdir -p "$icon_dest"
        install -m 644 "${tray_dir}/icons/"*.svg "$icon_dest/" 2>/dev/null || true
        print_success "Installed icons to: $icon_dest"
    fi

    # Install desktop file
    if [ -f "${tray_dir}/rt-audio-tray.desktop" ]; then
        install -m 644 "${tray_dir}/rt-audio-tray.desktop" "/usr/share/applications/"
        print_success "Installed desktop entry"
    fi

    print_success "Tray components installed"
    print_info "Start tray manually with: rt-audio-tray"
    print_info "To enable auto-updates, set TRAY_ENABLED=\"true\" in $CONFIG_FILE"
}

# Remove tray components during uninstall
uninstall_tray_components() {
    print_step "Removing tray components..."

    # Remove tray script
    rm -f "${INSTALL_BIN}/rt-audio-tray"

    # Remove icons
    rm -rf "/usr/share/icons/realtime-audio"

    # Remove desktop file
    rm -f "/usr/share/applications/rt-audio-tray.desktop"

    # Remove tray state file
    rm -f "/var/run/rt-audio-tray-state"

    print_success "Tray components removed"
}

# ============================================================================
# MIGRATION FROM OLD MOTU M4 OPTIMIZER
# ============================================================================

# Old installation paths (motu-m4-dynamic-optimizer)
OLD_SCRIPT_NAME="motu-m4-dynamic-optimizer"
OLD_INSTALL_BIN="/usr/local/bin"
OLD_SYSTEMD_DIR="/etc/systemd/system"
OLD_UDEV_DIR="/etc/udev/rules.d"
OLD_CONFIG_FILE="/etc/motu-m4-optimizer.conf"
OLD_CONFIG_EXAMPLE="/etc/motu-m4-optimizer.conf.example"
OLD_TRAY_SCRIPT="/usr/local/bin/motu-m4-tray"

# Check if old installation exists
check_old_installation() {
    local found=false

    [ -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh" ] && found=true
    [ -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}" ] && found=true
    [ -f "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}.service" ] && found=true
    [ -f "${OLD_UDEV_DIR}/99-motu-m4-audio-optimizer.rules" ] && found=true
    [ -f "$OLD_CONFIG_FILE" ] && found=true
    [ -f "$OLD_TRAY_SCRIPT" ] && found=true

    echo "$found"
}

# Create backup of old installation
backup_old_installation() {
    local backup_dir="/var/backup/motu-m4-optimizer-$(date +%Y%m%d_%H%M%S)"

    print_step "Creating backup of old installation..."
    mkdir -p "$backup_dir"

    # Backup scripts
    [ -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh" ] && \
        cp "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh" "$backup_dir/" 2>/dev/null
    [ -f "$OLD_TRAY_SCRIPT" ] && \
        cp "$OLD_TRAY_SCRIPT" "$backup_dir/" 2>/dev/null

    # Backup services
    [ -f "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}.service" ] && \
        cp "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}.service" "$backup_dir/" 2>/dev/null
    [ -f "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}-delayed.service" ] && \
        cp "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}-delayed.service" "$backup_dir/" 2>/dev/null

    # Backup udev rules
    for rules_file in "${OLD_UDEV_DIR}"/99-motu-m4-audio-optimizer.rules*; do
        [ -f "$rules_file" ] && cp "$rules_file" "$backup_dir/" 2>/dev/null
    done

    # Backup config
    [ -f "$OLD_CONFIG_FILE" ] && \
        cp "$OLD_CONFIG_FILE" "$backup_dir/" 2>/dev/null
    [ -f "$OLD_CONFIG_EXAMPLE" ] && \
        cp "$OLD_CONFIG_EXAMPLE" "$backup_dir/" 2>/dev/null

    print_success "Backup created: $backup_dir"
    echo "$backup_dir"
}

# Remove old installation
remove_old_installation() {
    print_step "Removing old MOTU M4 optimizer installation..."

    # Stop and disable old services
    systemctl stop "${OLD_SCRIPT_NAME}.service" 2>/dev/null || true
    systemctl stop "${OLD_SCRIPT_NAME}-delayed.service" 2>/dev/null || true
    systemctl disable "${OLD_SCRIPT_NAME}.service" 2>/dev/null || true
    systemctl disable "${OLD_SCRIPT_NAME}-delayed.service" 2>/dev/null || true
    print_success "Old services stopped and disabled"

    # Remove old scripts
    rm -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh"
    rm -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh.backup"*
    rm -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}"
    rm -f "$OLD_TRAY_SCRIPT"
    print_success "Old scripts removed"

    # Remove old services
    rm -f "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}.service"
    rm -f "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}-delayed.service"
    print_success "Old service files removed"

    # Remove old udev rules (including backups)
    rm -f "${OLD_UDEV_DIR}/99-motu-m4-audio-optimizer.rules"
    rm -f "${OLD_UDEV_DIR}/99-motu-m4-audio-optimizer.rules.backup"*
    print_success "Old udev rules removed"

    # Remove old config example (keep user config for reference)
    rm -f "$OLD_CONFIG_EXAMPLE"

    # Reload daemons
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true

    print_success "Old MOTU M4 optimizer removed"
}

# Migrate from old installation
migrate_from_motu_m4() {
    local old_exists
    old_exists=$(check_old_installation)

    if [ "$old_exists" = "true" ]; then
        echo ""
        print_warning "Old MOTU M4 optimizer installation detected!"
        echo ""
        echo "  Found components:"
        [ -f "${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh" ] && echo "    - Script: ${OLD_INSTALL_BIN}/${OLD_SCRIPT_NAME}.sh"
        [ -f "${OLD_SYSTEMD_DIR}/${OLD_SCRIPT_NAME}.service" ] && echo "    - Service: ${OLD_SCRIPT_NAME}.service"
        [ -f "${OLD_UDEV_DIR}/99-motu-m4-audio-optimizer.rules" ] && echo "    - Udev rules: 99-motu-m4-audio-optimizer.rules"
        [ -f "$OLD_CONFIG_FILE" ] && echo "    - Config: $OLD_CONFIG_FILE"
        [ -f "$OLD_TRAY_SCRIPT" ] && echo "    - Tray: $OLD_TRAY_SCRIPT"
        echo ""

        read -p "Do you want to migrate to the new generic optimizer? [Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            # Create backup
            local backup_dir
            backup_dir=$(backup_old_installation)

            # Remove old installation
            remove_old_installation

            echo ""
            print_success "Migration preparation complete!"
            print_info "Old configuration backed up to: $backup_dir"

            # Check if old config had custom settings
            if [ -f "$backup_dir/motu-m4-optimizer.conf" ]; then
                print_info "Your old settings were saved. You may want to transfer them to:"
                print_info "  /etc/realtime-audio-optimizer.conf"
            fi
            echo ""

            return 0
        else
            print_warning "Migration cancelled. Old installation will remain."
            echo ""
            read -p "Continue with parallel installation? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Installation cancelled."
                exit 0
            fi
        fi
    fi

    return 0
}

# ============================================================================
# INSTALLATION
# ============================================================================

do_install() {
    print_header
    check_root "install"
    check_source_files

    # Check for old MOTU M4 optimizer and offer migration
    migrate_from_motu_m4

    echo ""
    print_info "Installing Realtime Audio Optimizer..."
    echo ""

    # Stop existing service if running
    if systemctl is-active --quiet "${SCRIPT_NAME}.service" 2>/dev/null; then
        print_step "Stopping existing service..."
        systemctl stop "${SCRIPT_NAME}.service" 2>/dev/null || true
        print_success "Service stopped"
    fi

    # Create library directory
    print_step "Creating library directory..."
    mkdir -p "$INSTALL_LIB"
    print_success "Created $INSTALL_LIB"

    # Copy library modules
    print_step "Installing library modules..."
    cp -r "${LIB_DIR}/"*.sh "$INSTALL_LIB/"
    chmod 644 "${INSTALL_LIB}/"*.sh
    print_success "Installed $(ls -1 "${INSTALL_LIB}/"*.sh | wc -l) modules to $INSTALL_LIB"

    # Create wrapper script that uses installed library
    print_step "Installing main script..."

    # Create a modified version that points to installed lib location
    cat > "${INSTALL_BIN}/${SCRIPT_NAME}.sh" << 'WRAPPER_EOF'
#!/bin/bash

# Realtime Audio Optimizer v4 - Hybrid Strategy (Stability-optimized)
# Installed wrapper script

# Note: Do NOT use "set -e" here - many operations may fail non-critically
# (e.g., IRQ threading not supported, some kernel params not available)

# Use installed library location
SCRIPT_DIR="/usr/local/lib/realtime-audio-optimizer"
LIB_DIR="$SCRIPT_DIR"

# Check if lib directory exists
if [ ! -d "$LIB_DIR" ]; then
    echo "❌ Error: Library directory not found: $LIB_DIR"
    echo "   Please reinstall the optimizer."
    exit 1
fi

# List of required modules in load order
REQUIRED_MODULES=(
    "config.sh" "logging.sh" "interfaces.sh" "checks.sh" "jack.sh" "xrun.sh"
    "process.sh" "usb.sh" "kernel.sh" "optimization.sh"
    "status.sh" "monitor.sh"
)

# Optional modules (loaded if present)
OPTIONAL_MODULES=("tray.sh")

# Load all required modules
for module in "${REQUIRED_MODULES[@]}"; do
    module_path="$LIB_DIR/$module"
    if [ -f "$module_path" ]; then
        source "$module_path"
    else
        echo "❌ Error: Required module not found: $module_path"
        exit 1
    fi
done

# Load optional modules (no error if missing)
for module in "${OPTIONAL_MODULES[@]}"; do
    module_path="$LIB_DIR/$module"
    if [ -f "$module_path" ]; then
        source "$module_path"
    fi
done

# Show help
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
    echo "Supported: All USB Audio Class compliant devices"
}

# Show detected interfaces
show_detected_interfaces() {
    echo "$OPTIMIZER_NAME v$OPTIMIZER_VERSION"
    echo ""
    echo "Detecting USB audio interfaces..."
    echo ""

    local interfaces
    interfaces=$(detect_usb_audio_interfaces)

    if [ -z "$interfaces" ]; then
        echo "No USB audio interfaces found."
        return 1
    fi

    echo "Detected interfaces:"
    echo ""

    local count=0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        count=$((count + 1))

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
    echo "Run 'sudo realtime-audio-optimizer once' to activate optimizations."
}

# Main command handler
case "${1:-monitor}" in
    "monitor"|"daemon")
        main_monitoring_loop
        ;;
    "live-xruns"|"xrun-monitor")
        live_xrun_monitoring
        ;;
    "once"|"run")
        motu_connected=$(check_audio_interfaces)
        if [ "$motu_connected" = "true" ]; then
            log_info "🎵 One-time activation of Hybrid Audio Optimizations"
            activate_audio_optimizations
        else
            log_info "🔧 audio interface not detected - Deactivating optimizations"
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
    "stop"|"reset")
        log_info "Manual reset requested"
        deactivate_audio_optimizations
        ;;
    "detect"|"list"|"interfaces")
        show_detected_interfaces
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
WRAPPER_EOF

    chmod +x "${INSTALL_BIN}/${SCRIPT_NAME}.sh"
    print_success "Installed main script to ${INSTALL_BIN}/${SCRIPT_NAME}.sh"

    # Create symlink without .sh extension for convenience
    print_step "Creating convenience symlink..."
    ln -sf "${INSTALL_BIN}/${SCRIPT_NAME}.sh" "${INSTALL_BIN}/${SCRIPT_NAME}"
    print_success "Created symlink: ${INSTALL_BIN}/${SCRIPT_NAME}"

    # Install systemd service
    if [ -f "$SERVICE_FILE" ]; then
        print_step "Installing systemd service..."
        cp "$SERVICE_FILE" "${SYSTEMD_DIR}/"
        chmod 644 "${SYSTEMD_DIR}/${SCRIPT_NAME}.service"
        print_success "Installed service file"
    fi

    # Install delayed service if exists
    if [ -f "$DELAYED_SERVICE_FILE" ]; then
        print_step "Installing delayed systemd service..."
        cp "$DELAYED_SERVICE_FILE" "${SYSTEMD_DIR}/"
        chmod 644 "${SYSTEMD_DIR}/${SCRIPT_NAME}-delayed.service"
        print_success "Installed delayed service file"
    fi

    # Install udev rules
    if [ -f "$UDEV_RULES" ]; then
        print_step "Installing udev rules..."
        cp "$UDEV_RULES" "${UDEV_DIR}/"
        chmod 644 "${UDEV_DIR}/99-realtime-audio-optimizer.rules"
        print_success "Installed udev rules"
    fi

    # Install example configuration file
    if [ -f "$EXAMPLE_CONFIG" ]; then
        print_step "Installing example configuration file..."
        cp "$EXAMPLE_CONFIG" "/etc/realtime-audio-optimizer.conf.example"
        chmod 644 "/etc/realtime-audio-optimizer.conf.example"
        print_success "Installed example config: /etc/realtime-audio-optimizer.conf.example"
        if [ ! -f "$CONFIG_FILE" ]; then
            print_info "To customize settings, copy to $CONFIG_FILE and edit"
        else
            print_info "User configuration exists: $CONFIG_FILE"
        fi
    fi

    # Create log file with correct permissions
    print_step "Setting up log file..."
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    print_success "Created log file: $LOG_FILE"

    # Reload systemd and udev
    print_step "Reloading system daemons..."
    systemctl daemon-reload
    if [ -f "$UDEV_RULES" ]; then
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=usb
    fi
    print_success "System daemons reloaded"

    # Enable service (but don't start - udev will handle that)
    if [ -f "${SYSTEMD_DIR}/${SCRIPT_NAME}.service" ]; then
        print_step "Enabling service..."
        systemctl enable "${SCRIPT_NAME}.service" 2>/dev/null || true
        print_success "Service enabled (will start automatically when audio interface is connected)"
    fi

    # Install tray components (optional)
    install_tray_components

    echo ""
    print_success "Installation complete!"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Usage:"
    echo "    ${SCRIPT_NAME} status      - Show current status"
    echo "    ${SCRIPT_NAME} detailed    - Detailed hardware info"
    echo "    ${SCRIPT_NAME} live-xruns  - Live xrun monitoring"
    echo "    ${SCRIPT_NAME} once        - One-time optimization"
    echo ""
    echo "  System Tray (optional):"
    echo "    rt-audio-tray              - Start system tray icon"
    echo ""
    echo "  The optimizer will automatically activate when audio interface is connected."
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# UNINSTALLATION
# ============================================================================

do_uninstall() {
    print_header
    check_root "uninstall"

    echo ""
    print_info "Uninstalling Realtime Audio Optimizer..."
    echo ""

    # Stop and disable service
    print_step "Stopping and disabling services..."
    systemctl stop "${SCRIPT_NAME}.service" 2>/dev/null || true
    systemctl stop "${SCRIPT_NAME}-delayed.service" 2>/dev/null || true
    systemctl disable "${SCRIPT_NAME}.service" 2>/dev/null || true
    systemctl disable "${SCRIPT_NAME}-delayed.service" 2>/dev/null || true
    print_success "Services stopped and disabled"

    # Remove main script and symlink
    print_step "Removing scripts..."
    rm -f "${INSTALL_BIN}/${SCRIPT_NAME}.sh"
    rm -f "${INSTALL_BIN}/${SCRIPT_NAME}"
    print_success "Removed scripts from ${INSTALL_BIN}"

    # Remove library directory
    print_step "Removing library modules..."
    rm -rf "$INSTALL_LIB"
    print_success "Removed $INSTALL_LIB"

    # Remove systemd services
    print_step "Removing systemd services..."
    rm -f "${SYSTEMD_DIR}/${SCRIPT_NAME}.service"
    rm -f "${SYSTEMD_DIR}/${SCRIPT_NAME}-delayed.service"
    print_success "Removed service files"

    # Remove udev rules
    print_step "Removing udev rules..."
    rm -f "${UDEV_DIR}/99-realtime-audio-optimizer.rules"
    print_success "Removed udev rules"

    # Remove tray components
    uninstall_tray_components

    # Reload daemons
    print_step "Reloading system daemons..."
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    print_success "System daemons reloaded"

    # Remove example configuration file
    print_step "Removing example configuration file..."
    rm -f "/etc/realtime-audio-optimizer.conf.example"
    print_success "Removed example configuration file"

    # Ask about user configuration file
    if [ -f "$CONFIG_FILE" ]; then
        echo ""
        read -p "Do you want to remove your configuration file ($CONFIG_FILE)? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$CONFIG_FILE"
            print_success "Removed configuration file"
        else
            print_info "Configuration file kept at $CONFIG_FILE"
        fi
    fi

    # Ask about log file
    echo ""
    read -p "Do you want to remove the log file ($LOG_FILE)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$LOG_FILE"
        print_success "Removed log file"
    else
        print_info "Log file kept at $LOG_FILE"
    fi

    # Remove state file
    rm -f /var/run/rt-audio-state

    echo ""
    print_success "Uninstallation complete!"
    echo ""
}

# ============================================================================
# UPDATE
# ============================================================================

do_update() {
    print_header
    check_root "update"
    check_source_files

    echo ""
    print_info "Updating Realtime Audio Optimizer..."
    echo ""

    # Check if already installed
    if [ ! -d "$INSTALL_LIB" ]; then
        print_warning "Optimizer is not installed. Running full installation..."
        do_install
        return
    fi

    # Stop service temporarily
    local was_running=false
    if systemctl is-active --quiet "${SCRIPT_NAME}.service" 2>/dev/null; then
        print_step "Stopping service for update..."
        systemctl stop "${SCRIPT_NAME}.service"
        was_running=true
        print_success "Service stopped"
    fi

    # Update library modules
    print_step "Updating library modules..."
    cp -r "${LIB_DIR}/"*.sh "$INSTALL_LIB/"
    chmod 644 "${INSTALL_LIB}/"*.sh
    print_success "Updated $(ls -1 "${INSTALL_LIB}/"*.sh | wc -l) modules"

    # Update main script (regenerate wrapper)
    print_step "Updating main script..."
    # Re-run the install to regenerate the wrapper script
    do_install > /dev/null 2>&1 || true
    print_success "Updated main script"

    # Reload daemons
    print_step "Reloading system daemons..."
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    print_success "System daemons reloaded"

    # Restart service if it was running
    if [ "$was_running" = true ]; then
        print_step "Restarting service..."
        systemctl start "${SCRIPT_NAME}.service"
        print_success "Service restarted"
    fi

    echo ""
    print_success "Update complete!"
    echo ""
}

# ============================================================================
# STATUS CHECK
# ============================================================================

do_status() {
    print_header

    echo "Installation Status:"
    echo ""

    # Check main script
    if [ -x "${INSTALL_BIN}/${SCRIPT_NAME}.sh" ]; then
        print_success "Main script installed: ${INSTALL_BIN}/${SCRIPT_NAME}.sh"
    else
        print_error "Main script NOT installed"
    fi

    # Check symlink
    if [ -L "${INSTALL_BIN}/${SCRIPT_NAME}" ]; then
        print_success "Symlink exists: ${INSTALL_BIN}/${SCRIPT_NAME}"
    else
        print_warning "Symlink missing"
    fi

    # Check library directory
    if [ -d "$INSTALL_LIB" ]; then
        local module_count
        module_count=$(ls -1 "${INSTALL_LIB}/"*.sh 2>/dev/null | wc -l)
        print_success "Library installed: $INSTALL_LIB ($module_count modules)"
    else
        print_error "Library NOT installed"
    fi

    # Check systemd service
    if [ -f "${SYSTEMD_DIR}/${SCRIPT_NAME}.service" ]; then
        print_success "Systemd service installed"
        if systemctl is-enabled --quiet "${SCRIPT_NAME}.service" 2>/dev/null; then
            print_success "Service is enabled"
        else
            print_warning "Service is disabled"
        fi
        if systemctl is-active --quiet "${SCRIPT_NAME}.service" 2>/dev/null; then
            print_success "Service is running"
        else
            print_info "Service is not running"
        fi
    else
        print_warning "Systemd service NOT installed"
    fi

    # Check udev rules
    if [ -f "${UDEV_DIR}/99-realtime-audio-optimizer.rules" ]; then
        print_success "Udev rules installed"
    else
        print_warning "Udev rules NOT installed"
    fi

    # Check log file
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(du -h "$LOG_FILE" | cut -f1)
        print_success "Log file exists: $LOG_FILE ($log_size)"
    else
        print_info "Log file not created yet"
    fi

    # Check audio interface connection
    echo ""
    echo "Hardware Status:"
    echo ""
    if lsusb 2>/dev/null | grep -q "Mark of the Unicorn"; then
        print_success "audio interface is connected"
    else
        print_info "audio interface is NOT connected"
    fi

    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

show_usage() {
    echo "Realtime Audio Optimizer - Installer"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  install    - Install the optimizer"
    echo "  uninstall  - Remove the optimizer"
    echo "  update     - Update existing installation"
    echo "  status     - Check installation status"
    echo ""
}

case "${1:-}" in
    install)
        do_install
        ;;
    uninstall|remove)
        do_uninstall
        ;;
    update|upgrade)
        do_update
        ;;
    status|check)
        do_status
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
