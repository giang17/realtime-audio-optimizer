# Realtime Audio Optimizer

A Linux tool for optimizing system performance for professional USB audio interfaces. Works with **any USB Audio Class compliant device** including MOTU, Focusrite, Behringer, PreSonus, and more.

## Features

- **Auto-Detection**: Automatically detects all connected USB audio interfaces
- **CPU Optimization**: Intelligent CPU governor management for P-Cores and E-Cores
- **Process Affinity**: Pins audio processes (JACK, PipeWire, DAWs) to optimal CPU cores
- **IRQ Optimization**: Dedicates CPU cores for USB and audio interrupt handling
- **USB Power Management**: Disables autosuspend to prevent audio dropouts
- **Kernel Tuning**: Optimizes scheduler parameters for low-latency audio
- **Real-time Priorities**: Sets SCHED_FIFO priorities for audio processes
- **Live Monitoring**: Real-time xrun monitoring and performance statistics
- **System Tray**: Optional status indicator with PyQt5 or yad

## Supported Audio Interfaces

Works with any USB Audio Class 1.0/2.0 compliant device, including:

- MOTU (M4, M2, UltraLite, etc.)
- Focusrite (Scarlett series, Clarett, etc.)
- Behringer (UMC series, U-PHORIA, etc.)
- Steinberg (UR series, etc.)
- PreSonus (Studio series, AudioBox, etc.)
- Universal Audio (Volt series)
- Audient, Native Instruments, RME, and more

## Requirements

- Linux with ALSA sound support
- Root privileges for system optimizations
- Optional: python3-pyqt5 for system tray

## Installation

```bash
git clone https://github.com/giang17/realtime-audio-optimizer.git
cd realtime-audio-optimizer
sudo ./install.sh install
```

## Usage

### Command Line

```bash
# Show detected audio interfaces
realtime-audio-optimizer detect

# One-time optimization
sudo realtime-audio-optimizer once

# Continuous monitoring (daemon mode)
sudo realtime-audio-optimizer monitor

# Show status
realtime-audio-optimizer status

# Detailed hardware info
realtime-audio-optimizer detailed

# Live xrun monitoring
realtime-audio-optimizer live-xruns

# Deactivate optimizations
sudo realtime-audio-optimizer stop
```

### Automatic Mode

The optimizer automatically activates when a USB audio interface is connected via udev rules.

### System Tray

```bash
rt-audio-tray
```

## CPU Strategy (Intel 12th/13th Gen Hybrid)

The optimizer uses a hybrid strategy optimized for Intel Alder Lake / Raptor Lake CPUs:

| CPU Range | Type | Governor | Purpose |
|-----------|------|----------|---------|
| 0-5 | P-Cores | Performance | DAWs, Plugins |
| 6-7 | P-Cores | Performance | JACK/PipeWire |
| 8-13 | E-Cores | Powersave | Background tasks |
| 14-19 | E-Cores | Performance | IRQ handling |

Adjust CPU ranges in `/etc/realtime-audio-optimizer.conf` for different CPU configurations.

## Configuration

Copy the example config and customize:

```bash
sudo cp /etc/realtime-audio-optimizer.conf.example /etc/realtime-audio-optimizer.conf
sudo nano /etc/realtime-audio-optimizer.conf
```

### Key Configuration Options

```bash
# CPU assignments (adjust for your CPU)
IRQ_CPUS="14-19"
AUDIO_MAIN_CPUS="6-7"
DAW_CPUS="0-5"
BACKGROUND_CPUS="8-13"
ALL_CPUS="0-19"

# RT priority levels
RT_PRIORITY_JACK=99
RT_PRIORITY_PIPEWIRE=85
RT_PRIORITY_AUDIO=70

# Additional audio processes to optimize
EXTRA_AUDIO_PROCESSES="my-custom-daw my-synth"

# Enable system tray updates
TRAY_ENABLED="true"
```

## Troubleshooting

### Check detected interfaces
```bash
realtime-audio-optimizer detect
```

### View logs
```bash
# System log
journalctl -u realtime-audio-optimizer.service

# Application log
cat /var/log/realtime-audio-optimizer.log
```

### Manual service control
```bash
sudo systemctl status realtime-audio-optimizer
sudo systemctl start realtime-audio-optimizer
sudo systemctl stop realtime-audio-optimizer
```

## Uninstallation

```bash
sudo ./install.sh uninstall
```

## Credits

Based on [MOTU M4 Dynamic Optimizer](https://github.com/giang17/motu-m4-dynamic-optimizer).

## License

MIT License
