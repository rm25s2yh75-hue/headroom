# Headroom

A lightweight macOS menu bar app for monitoring system performance at a glance.

![macOS](https://img.shields.io/badge/macOS-11.0%2B-blue) ![Version](https://img.shields.io/badge/version-1.3.0-green) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

---

## Features

- **System Pressure Dot** — a single colour-coded indicator in your menu bar showing overall system health
- **Live Stats** — RAM usage %, CPU usage %, System Pressure %, and Swap Pressure % optionally shown in the menu bar
- **Graphs** — live line charts for System Pressure, RAM, CPU, and Swap Pressure (2×2 grid, each toggleable)
- **Top Apps** — ranked lists of the processes using the most RAM, CPU, and swap pressure
- **Network Speed** — live download and upload throughput across all active interfaces
- **System Uptime** — time since last restart
- **Notifications** — optional alert when system pressure reaches High
- **Auto-updates** — checks GitHub for new versions on launch
- **Launch at login** — optional LaunchAgent support
- **Refresh rate** — configurable at 1s, 2s (default), 5s, or 10s

---

## System Pressure Dot

The dot reflects a combined RAM + CPU pressure score (0–100%):

| Dot | Score | Meaning |
|-----|-------|---------|
| 🟢 Green | < 50% | Healthy — system is in good shape |
| 🟡 Amber | 50–74% | Moderate — RAM compressing or CPU under load |
| 🔴 Red | ≥ 75% | High — heavy swap or CPU, performance may suffer |

The score is calculated as:
- **70% weight** — RAM compression ratio (how hard macOS is compressing memory)
- **30% weight** — CPU usage

---

## Show / Hide

All menu bar items and graphs are individually toggleable from the **Show / Hide** section without closing the menu:

- System Pressure Dot
- RAM Usage %
- CPU Usage %
- System Pressure %
- Swap Pressure %
- System Pressure Graph
- RAM Usage Graph
- CPU Usage Graph
- Swap Pressure Graph

---

## Installation

1. Download **Headroom.dmg** from the [latest release](https://github.com/rm25s2yh75-hue/headroom/releases/latest)
2. Open the DMG and drag **Headroom.app** to your Applications folder
3. Launch Headroom — it will appear in your menu bar

> **First launch:** macOS may show a security prompt since the app is not notarised. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

---

## Building from Source

Requires Xcode Command Line Tools.

```bash
git clone https://github.com/rm25s2yh75-hue/headroom.git
cd headroom
./build.sh
```

The script compiles a universal binary (arm64 + x86_64), embeds Swift libraries, and produces both `Headroom.app` and `Headroom.dmg`.

---

## Requirements

- macOS 11.0 (Big Sur) or later
- Apple Silicon or Intel Mac

---

## Privacy

Headroom reads only local system metrics via macOS kernel APIs. No data is collected, transmitted, or stored beyond your own machine.

---

## Support

If you find Headroom useful, consider buying me a coffee:
[ko-fi.com/jasa49](https://ko-fi.com/jasa49)
