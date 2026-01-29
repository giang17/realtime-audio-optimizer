#!/usr/bin/env python3
"""
Realtime Audio Optimizer - System Tray Application (PyQt5)

Provides a system tray icon for status display and quick actions.
Replaces the yad-based implementation for better KDE integration.

Usage:
    rt-audio-tray         - Start the tray icon
    rt-audio-tray --help  - Show help

Requirements:
    - python3-pyqt5 package
    - Desktop environment with system tray support

The tray icon reads status from /var/run/rt-audio-tray-state
which is written by the main optimizer service.
"""

import os
import sys
import glob
import subprocess
from pathlib import Path

from PyQt5.QtWidgets import QApplication, QSystemTrayIcon, QMenu, QAction
from PyQt5.QtGui import QIcon, QPixmap, QPainter, QColor, QBrush, QPen, QCursor
from PyQt5.QtCore import QTimer, Qt, QRectF
from PyQt5.QtSvg import QSvgRenderer

# Configuration
TRAY_NAME = "Realtime Audio Optimizer"
STATE_FILE = os.environ.get("TRAY_STATE_FILE", "/var/run/rt-audio-tray-state")
ICON_DIR = os.environ.get("TRAY_ICON_DIR", "/usr/share/icons/realtime-audio")
UPDATE_INTERVAL = int(os.environ.get("TRAY_UPDATE_INTERVAL", "5")) * 1000  # ms
OPTIMIZER_CMD = "realtime-audio-optimizer"

# Icons
ICON_OPTIMIZED = f"{ICON_DIR}/motu-optimized.svg"
ICON_CONNECTED = f"{ICON_DIR}/motu-connected.svg"
ICON_WARNING = f"{ICON_DIR}/motu-warning.svg"
ICON_DISCONNECTED = f"{ICON_DIR}/motu-disconnected.svg"


def create_fallback_icon(color: str, has_check: bool = False) -> QIcon:
    """Create a simple fallback icon if SVG loading fails."""
    size = 22
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.transparent)

    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.Antialiasing)

    # Color mapping
    colors = {
        "green": QColor("#22c55e"),
        "blue": QColor("#3b82f6"),
        "yellow": QColor("#eab308"),
        "gray": QColor("#6b7280"),
    }
    fill_color = colors.get(color, colors["gray"])

    # Draw circle background
    painter.setBrush(QBrush(fill_color))
    painter.setPen(QPen(fill_color.darker(120), 1))
    painter.drawEllipse(1, 1, size - 2, size - 2)

    # Draw audio bars
    painter.setPen(Qt.NoPen)
    painter.setBrush(QBrush(Qt.white))
    bar_positions = [(5, 9, 2, 4), (8, 6, 2, 10), (11, 8, 2, 6), (14, 5, 2, 12)]
    for x, y, w, h in bar_positions:
        painter.drawRoundedRect(x, y, w, h, 0.5, 0.5)

    painter.end()
    return QIcon(pixmap)


def load_svg_icon(path: str, fallback_color: str = "gray") -> QIcon:
    """Load SVG icon with fallback to generated icon."""
    if os.path.exists(path):
        # Try QSvgRenderer for better SVG support
        renderer = QSvgRenderer(path)
        if renderer.isValid():
            size = 22
            pixmap = QPixmap(size, size)
            pixmap.fill(Qt.transparent)
            painter = QPainter(pixmap)
            renderer.render(painter)
            painter.end()
            return QIcon(pixmap)

        # Fallback: try QIcon directly
        icon = QIcon(path)
        if not icon.isNull():
            return icon

    # Final fallback: generate icon
    return create_fallback_icon(fallback_color)


class AudioOptimizerTray(QSystemTrayIcon):
    """System tray icon for Realtime Audio Optimizer."""

    def __init__(self, parent=None):
        super().__init__(parent)

        self.last_state = ""
        self.last_motu_connected = None  # Keep variable name for compatibility
        self.last_xruns = "0"

        # Set initial icon and tooltip
        self.update_tray()

        # Create context menu
        self.setContextMenu(self.create_menu())

        # Setup polling timer
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_tray)
        self.timer.start(UPDATE_INTERVAL)

        # Left-click also shows menu (like yad behavior)
        self.activated.connect(self.on_activated)

    def check_audio_interface_connected(self) -> bool:
        """Check if any USB Audio Interface is connected via ALSA."""
        # Check ALSA cards for USB audio devices
        for card_path in glob.glob("/proc/asound/card*"):
            # Check for usbid file (present for USB audio devices)
            usbid_file = Path(card_path) / "usbid"
            if usbid_file.exists():
                return True

            # Alternative: check usbbus file
            usbbus_file = Path(card_path) / "usbbus"
            if usbbus_file.exists():
                return True

            # Alternative: check stream0 for USB Audio signature
            stream0_file = Path(card_path) / "stream0"
            if stream0_file.exists():
                try:
                    content = stream0_file.read_text()
                    if "USB Audio" in content:
                        return True
                except (IOError, OSError):
                    pass

        return False

    def get_interface_name(self) -> str:
        """Get the name of the connected USB audio interface."""
        for card_path in glob.glob("/proc/asound/card*"):
            # Check for usbid file (present for USB audio devices)
            usbid_file = Path(card_path) / "usbid"
            usbbus_file = Path(card_path) / "usbbus"
            stream0_file = Path(card_path) / "stream0"

            is_usb = usbid_file.exists() or usbbus_file.exists()

            if not is_usb and stream0_file.exists():
                try:
                    content = stream0_file.read_text()
                    is_usb = "USB Audio" in content
                except (IOError, OSError):
                    pass

            if is_usb:
                # Try to get friendly name from stream0
                if stream0_file.exists():
                    try:
                        first_line = stream0_file.read_text().split('\n')[0]
                        # Remove " at usb-..." suffix
                        name = first_line.split(" at usb")[0].strip()
                        if name:
                            return name
                    except (IOError, OSError):
                        pass

                # Fallback: use card ID
                id_file = Path(card_path) / "id"
                if id_file.exists():
                    try:
                        return id_file.read_text().strip()
                    except (IOError, OSError):
                        pass

        return "USB Audio"

    def get_jack_latency_info(self) -> str:
        """Get JACK latency info (buffer size, sample rate, periods)."""
        buffer_size = None
        sample_rate = None
        periods = None

        # Get buffer size from JACK
        try:
            result = subprocess.run(
                ["jack_bufsize"],
                capture_output=True,
                text=True,
                timeout=2
            )
            if result.returncode == 0:
                buffer_size = int(result.stdout.strip())
        except (subprocess.SubprocessError, FileNotFoundError, ValueError):
            pass

        # Get sample rate from JACK
        try:
            result = subprocess.run(
                ["jack_samplerate"],
                capture_output=True,
                text=True,
                timeout=2
            )
            if result.returncode == 0:
                sample_rate = int(result.stdout.strip())
        except (subprocess.SubprocessError, FileNotFoundError, ValueError):
            pass

        # Get periods from ALSA hw_params
        for hw_params in glob.glob("/proc/asound/card*/pcm*/sub*/hw_params"):
            try:
                content = Path(hw_params).read_text()
                if "closed" in content:
                    continue
                period_size = None
                alsa_buffer_size = None
                for line in content.split('\n'):
                    if line.startswith("period_size:"):
                        period_size = int(line.split(':')[1].strip())
                    elif line.startswith("buffer_size:"):
                        alsa_buffer_size = int(line.split(':')[1].strip())
                if period_size and alsa_buffer_size:
                    periods = alsa_buffer_size // period_size
                    break
            except (IOError, OSError, ValueError):
                pass

        # Format output
        if buffer_size and sample_rate:
            latency_ms = (buffer_size / sample_rate) * 1000
            if periods and periods > 1:
                return f"{buffer_size}@{sample_rate}Hz, {periods}p ({latency_ms:.1f}ms)"
            else:
                return f"{buffer_size}@{sample_rate}Hz ({latency_ms:.1f}ms)"
        elif buffer_size:
            return f"{buffer_size} samples"

        # Fallback: check if JACK is running
        try:
            result = subprocess.run(
                ["jack_lsp"],
                capture_output=True,
                text=True,
                timeout=2
            )
            if result.returncode == 0:
                return "Active"
        except (subprocess.SubprocessError, FileNotFoundError):
            pass

        return ""

    # Keep old method name for compatibility
    def check_motu_connected(self) -> bool:
        """Alias for check_audio_interface_connected (backward compatibility)."""
        return self.check_audio_interface_connected()

    def read_state_file(self) -> dict:
        """Read and parse the state file."""
        state = {
            "state": "connected",
            "jack": "inactive",
            "jack_settings": "unknown",
            "xruns_30s": "0"
        }

        if not os.path.exists(STATE_FILE):
            return state

        try:
            with open(STATE_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if "=" in line:
                        key, value = line.split("=", 1)
                        state[key] = value
        except (IOError, OSError):
            pass

        return state

    def get_current_icon(self) -> QIcon:
        """Determine the appropriate icon based on device and state."""
        if not self.check_audio_interface_connected():
            return load_svg_icon(ICON_DISCONNECTED, "gray")

        state_data = self.read_state_file()
        state = state_data.get("state", "connected")

        if state == "optimized":
            return load_svg_icon(ICON_OPTIMIZED, "green")
        elif state == "warning":
            return load_svg_icon(ICON_WARNING, "yellow")
        else:
            return load_svg_icon(ICON_CONNECTED, "blue")

    def get_tooltip(self) -> str:
        """Generate tooltip text based on current status.

        Icon colors indicate status:
        - Green: Audio Interface connected and optimized
        - Blue: Audio Interface connected but not optimized
        - Orange: Warning (xruns detected)
        - Gray: Audio Interface not connected
        """
        if not self.check_audio_interface_connected():
            return f"{TRAY_NAME}\nNo Audio Interface"

        interface_name = self.get_interface_name()
        state_data = self.read_state_file()
        state = state_data.get("state", "connected")
        jack = state_data.get("jack", "inactive")

        # Status text
        if state == "optimized":
            status_text = "Optimized"
        elif state == "warning":
            status_text = "Warning"
        else:
            status_text = "Connected"

        lines = [TRAY_NAME, f"{interface_name}: {status_text}"]

        # JACK status with latency info
        if jack == "active":
            latency_info = self.get_jack_latency_info()
            if latency_info:
                lines.append(f"JACK: {latency_info}")
            else:
                lines.append("JACK: Active")
        else:
            lines.append("JACK: Inactive")

        return "\n".join(lines)

    def update_tray(self):
        """Update tray icon and tooltip."""
        interface_connected = self.check_audio_interface_connected()
        state_data = self.read_state_file()
        current_state = state_data.get("state", "connected") if interface_connected else "disconnected"
        current_xruns = state_data.get("xruns_30s", "0")

        # Update icon if state changed
        if interface_connected != self.last_motu_connected or current_state != self.last_state:
            self.setIcon(self.get_current_icon())
            self.setToolTip(self.get_tooltip())
            self.last_motu_connected = interface_connected
            self.last_state = current_state

        # Flash warning icon on xrun increase
        if interface_connected and current_xruns != self.last_xruns:
            try:
                if int(current_xruns) > int(self.last_xruns or "0"):
                    self.setIcon(load_svg_icon(ICON_WARNING, "yellow"))
                    QTimer.singleShot(2000, self.restore_icon)
            except ValueError:
                pass
            self.last_xruns = current_xruns

    def restore_icon(self):
        """Restore icon after warning flash."""
        self.setIcon(self.get_current_icon())

    def create_menu(self) -> QMenu:
        """Create the context menu."""
        menu = QMenu()

        # Status actions
        action_status = QAction("Show Status", menu)
        action_status.triggered.connect(self.action_status)
        menu.addAction(action_status)

        action_live = QAction("Live Xrun Monitor", menu)
        action_live.triggered.connect(self.action_live_monitor)
        menu.addAction(action_live)

        action_daemon = QAction("Daemon Monitor", menu)
        action_daemon.triggered.connect(self.action_daemon_monitor)
        menu.addAction(action_daemon)

        menu.addSeparator()

        # Optimization actions
        action_start = QAction("Start Optimization", menu)
        action_start.triggered.connect(self.action_start_optimization)
        menu.addAction(action_start)

        action_stop = QAction("Stop Optimization", menu)
        action_stop.triggered.connect(self.action_stop_optimization)
        menu.addAction(action_stop)

        menu.addSeparator()

        # Quit
        action_quit = QAction("Quit", menu)
        action_quit.triggered.connect(QApplication.quit)
        menu.addAction(action_quit)

        return menu

    def on_activated(self, reason):
        """Handle tray icon activation (left-click)."""
        if reason == QSystemTrayIcon.Trigger:
            # Show context menu on left-click too
            # Use cursor position for correct multi-monitor placement
            if self.contextMenu():
                self.contextMenu().popup(QCursor.pos())

    def find_terminal(self) -> str:
        """Find available terminal emulator."""
        terminals = ["x-terminal-emulator", "konsole", "gnome-terminal", "xterm"]
        for term in terminals:
            try:
                result = subprocess.run(
                    ["which", term],
                    capture_output=True,
                    timeout=2
                )
                if result.returncode == 0:
                    return term
            except subprocess.SubprocessError:
                pass
        return "xterm"

    def run_in_terminal(self, command: str, hold: bool = True):
        """Run a command in a terminal window."""
        terminal = self.find_terminal()

        if hold:
            bash_cmd = f"{command}; echo; read -p 'Press Enter to close...'"
        else:
            bash_cmd = command

        if terminal == "konsole":
            args = [terminal, "-e", "bash", "-c", bash_cmd]
        elif terminal == "gnome-terminal":
            args = [terminal, "--", "bash", "-c", bash_cmd]
        else:
            args = [terminal, "-e", f"bash -c '{bash_cmd}'"]

        try:
            subprocess.Popen(args)
        except subprocess.SubprocessError as e:
            self.showMessage(TRAY_NAME, f"Terminal error: {e}", QSystemTrayIcon.Warning)

    def action_status(self):
        """Show status in terminal."""
        self.run_in_terminal(f"{OPTIMIZER_CMD} status")

    def action_live_monitor(self):
        """Open live xrun monitoring."""
        self.run_in_terminal(f"{OPTIMIZER_CMD} live-xruns", hold=False)

    def action_daemon_monitor(self):
        """Open daemon monitor (requires root)."""
        self.run_in_terminal(f"pkexec {OPTIMIZER_CMD} monitor", hold=False)

    def action_start_optimization(self):
        """Start optimization (requires root)."""
        try:
            subprocess.Popen(["pkexec", OPTIMIZER_CMD, "once"])
            self.showMessage(TRAY_NAME, "Optimization started", QSystemTrayIcon.Information)
        except subprocess.SubprocessError as e:
            self.showMessage(TRAY_NAME, f"Error: {e}", QSystemTrayIcon.Warning)

    def action_stop_optimization(self):
        """Stop optimization (requires root)."""
        try:
            subprocess.Popen(["pkexec", OPTIMIZER_CMD, "stop"])
            self.showMessage(TRAY_NAME, "Optimization stopped", QSystemTrayIcon.Information)
        except subprocess.SubprocessError as e:
            self.showMessage(TRAY_NAME, f"Error: {e}", QSystemTrayIcon.Warning)


def show_help():
    """Display help message."""
    print(f"""{TRAY_NAME} - System Tray Application (PyQt5)

Usage: rt-audio-tray [OPTIONS]

Options:
  --help, -h      Show this help message
  --version, -v   Show version information

Description:
  Displays a system tray icon showing the current status of the
  Realtime Audio Optimizer. Right-click the icon for quick actions.

Menu Options:
  - Show Status        : Show detailed status in terminal
  - Live Xrun Monitor  : Open live xrun monitoring
  - Daemon Monitor     : Open daemon monitoring (root)
  - Start Optimization : Activate audio optimizations
  - Stop Optimization  : Deactivate optimizations
  - Quit               : Close the tray icon

Requirements:
  - python3-pyqt5 package
  - Desktop environment with system tray support

Configuration:
  The tray reads status from: {STATE_FILE}
  Icons are loaded from: {ICON_DIR}
""")


def show_version():
    """Display version information."""
    print(f"{TRAY_NAME} - Tray Application v2.0 (PyQt5)")


def main():
    """Main entry point."""
    # Handle command line arguments
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg in ("--help", "-h"):
            show_help()
            sys.exit(0)
        elif arg in ("--version", "-v"):
            show_version()
            sys.exit(0)
        else:
            print(f"Unknown option: {arg}")
            print("Use --help for usage information")
            sys.exit(1)

    # Set application name for proper KDE integration
    app = QApplication(sys.argv)
    app.setApplicationName("Audio Interface Optimizer")
    app.setApplicationDisplayName("Audio Interface Optimizer")
    app.setDesktopFileName("rt-audio-tray")
    app.setQuitOnLastWindowClosed(False)

    # Check system tray availability
    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("Error: System tray not available")
        sys.exit(1)

    # Create and show tray icon
    tray = AudioOptimizerTray()
    tray.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
