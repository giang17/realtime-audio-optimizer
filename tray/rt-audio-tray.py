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
TRAY_NAME = "Audio Interface Optimizer"
STATE_FILE = os.environ.get("TRAY_STATE_FILE", "/var/run/rt-audio-tray-state")
ICON_DIR = os.environ.get("TRAY_ICON_DIR", "/usr/share/icons/rt-audio")
UPDATE_INTERVAL = int(os.environ.get("TRAY_UPDATE_INTERVAL", "5")) * 1000  # ms
OPTIMIZER_CMD = "rt-audio-dynamic-optimizer"
MOTU_CARD_ID = os.environ.get("MOTU_CARD_ID", "M4")

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


class MotuM4Tray(QSystemTrayIcon):
    """System tray icon for Realtime Audio Optimizer."""

    def __init__(self, parent=None):
        super().__init__(parent)

        self.last_state = ""
        self.last_motu_connected = None
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

    def check_motu_connected(self) -> bool:
        """Check if Audio Interface is connected via ALSA or USB."""
        # Check ALSA cards - primary detection method
        for card_path in glob.glob("/proc/asound/card*"):
            id_file = Path(card_path) / "id"
            if id_file.exists():
                try:
                    card_id = id_file.read_text().strip()
                    if card_id == MOTU_CARD_ID:
                        return True
                except (IOError, OSError):
                    pass

        # Fallback: USB check
        try:
            result = subprocess.run(
                ["lsusb"],
                capture_output=True,
                text=True,
                timeout=5
            )
            if "Mark of the Unicorn" in result.stdout:
                return True
        except (subprocess.SubprocessError, FileNotFoundError):
            pass

        return False

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
        if not self.check_motu_connected():
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
        if not self.check_motu_connected():
            return f"{TRAY_NAME}\nGetrennt"

        state_data = self.read_state_file()
        state = state_data.get("state", "connected")
        jack = state_data.get("jack", "inactive")
        jack_settings = state_data.get("jack_settings", "")
        xruns = state_data.get("xruns_30s", "0")

        # Status line
        if state == "optimized":
            lines = [TRAY_NAME, "Optimiert"]
        elif state == "warning":
            lines = [TRAY_NAME, "Warnung - Xruns erkannt"]
        else:
            lines = [TRAY_NAME, "Verbunden"]

        # JACK status - check actual jack state, not jack_settings content
        if jack == "active":
            # Clean up jack_settings (remove emoji prefix if present)
            settings = jack_settings.replace("🎵 ", "").replace("🎵", "").strip()
            if settings and settings.lower() not in ("inactive", "unknown", ""):
                lines.append(f"JACK: {settings}")
            else:
                lines.append("JACK: Aktiv")
        else:
            lines.append("JACK: Inaktiv")

        # Xruns
        if xruns and xruns != "0":
            lines.append(f"Xruns (30s): {xruns}")

        return "\n".join(lines)

    def update_tray(self):
        """Update tray icon and tooltip."""
        motu_connected = self.check_motu_connected()
        state_data = self.read_state_file()
        current_state = state_data.get("state", "connected") if motu_connected else "disconnected"
        current_xruns = state_data.get("xruns_30s", "0")

        # Update icon if state changed
        if motu_connected != self.last_motu_connected or current_state != self.last_state:
            self.setIcon(self.get_current_icon())
            self.setToolTip(self.get_tooltip())
            self.last_motu_connected = motu_connected
            self.last_state = current_state

        # Flash warning icon on xrun increase
        if motu_connected and current_xruns != self.last_xruns:
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
        action_status = QAction("Status anzeigen", menu)
        action_status.triggered.connect(self.action_status)
        menu.addAction(action_status)

        action_live = QAction("Live Xrun-Monitor", menu)
        action_live.triggered.connect(self.action_live_monitor)
        menu.addAction(action_live)

        action_daemon = QAction("Daemon-Monitor", menu)
        action_daemon.triggered.connect(self.action_daemon_monitor)
        menu.addAction(action_daemon)

        menu.addSeparator()

        # Optimization actions
        action_start = QAction("Optimierung starten", menu)
        action_start.triggered.connect(self.action_start_optimization)
        menu.addAction(action_start)

        action_stop = QAction("Optimierung stoppen", menu)
        action_stop.triggered.connect(self.action_stop_optimization)
        menu.addAction(action_stop)

        menu.addSeparator()

        # Quit
        action_quit = QAction("Beenden", menu)
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
            bash_cmd = f"{command}; echo; read -p 'Druecke Enter...'"
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
            self.showMessage(TRAY_NAME, f"Terminal-Fehler: {e}", QSystemTrayIcon.Warning)

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
            self.showMessage(TRAY_NAME, "Optimierung gestartet", QSystemTrayIcon.Information)
        except subprocess.SubprocessError as e:
            self.showMessage(TRAY_NAME, f"Fehler: {e}", QSystemTrayIcon.Warning)

    def action_stop_optimization(self):
        """Stop optimization (requires root)."""
        try:
            subprocess.Popen(["pkexec", OPTIMIZER_CMD, "stop"])
            self.showMessage(TRAY_NAME, "Optimierung gestoppt", QSystemTrayIcon.Information)
        except subprocess.SubprocessError as e:
            self.showMessage(TRAY_NAME, f"Fehler: {e}", QSystemTrayIcon.Warning)


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
  - Status anzeigen     : Show detailed status in terminal
  - Live Xrun-Monitor   : Open live xrun monitoring
  - Daemon-Monitor      : Open daemon monitoring (root)
  - Optimierung starten : Activate audio optimizations
  - Optimierung stoppen : Deactivate optimizations
  - Beenden             : Close the tray icon

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
    tray = MotuM4Tray()
    tray.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
