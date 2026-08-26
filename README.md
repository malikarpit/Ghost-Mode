<div align="center">

  <img src="GhostMode_AppIcon.png" alt="Ghost Mode Icon" width="128" height="128" style="border-radius: 28px; box-shadow: 0 8px 24px rgba(0,0,0,0.25);" />

  # 👻 Ghost Mode for macOS

  **The Lightweight Closed-Lid Keep-Awake & Display Power Controller**

  [![macOS 12.0+](https://img.shields.io/badge/macOS-12.0%2B-blue.svg?style=flat&logo=apple)](https://apple.com)
  [![Architecture](https://img.shields.io/badge/Architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-brightgreen.svg)](https://apple.com)
  [![Language](https://img.shields.io/badge/Language-Swift%205.9%2B-orange.svg?logo=swift)](https://swift.org)
  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
  [![Developer: Arpit](https://img.shields.io/badge/Developer-Arpit-purple.svg)](https://github.com/malikarpit)
  [![GitHub Release](https://img.shields.io/github/v/release/malikarpit/Ghost-Mode?color=blue&label=Latest%20Release)](https://github.com/malikarpit/Ghost-Mode/releases/latest)

  <br />

  <a href="https://github.com/malikarpit/Ghost-Mode/releases/latest">
    <img src="https://img.shields.io/badge/📥%20Download-GhostMode--Installer.dmg-2ea44f?style=for-the-badge&logo=apple" alt="Download Ghost Mode" />
  </a>

</div>

---

## 🌟 What is Ghost Mode?

**Ghost Mode** is a fast, native macOS menu bar utility engineered to keep your Mac running heavy background workloads (such as AI agents, model downloads, long compilations, torrents, or server processes) with the **MacBook lid closed**, while **instantly powering down the display backlight** to eliminate thermal buildup and conserve battery life.

---

## 📥 Direct Download & Installation

### Option 1: Download Pre-built Universal DMG (Recommended)
1. Download the latest **`GhostMode-Installer.dmg`** from [**Releases**](https://github.com/malikarpit/Ghost-Mode/releases/latest).
2. Open the `.dmg` file and drag **Ghost Mode.app** into your **Applications** folder.
3. Launch **Ghost Mode** from Spotlight (`⌘ Space`) or Launchpad.

---

## ✨ Features

- 👻 **Closed-Lid Keep-Awake:** Prevents macOS clamshell sleep without needing an external monitor or power brick connected.
- ⚡ **Zero-Overhead Display Power-Down:** Shuts down internal screen backlights and display rendering pipelines immediately upon lid closure to preserve energy and keep temperatures low.
- 📊 **Dynamic Live Progress Header:** Embedded native dashboard in the menu bar with real-time color-shifting progress tracking (🟢 >50%, 🟠 15–50%, 🔴 <15%).
- 🔘 **1-Click Quick Controls:** Start default sessions, stop sessions, and add instant `+30m` timer extensions directly from the dashboard header.
- ⏱️ **Granular Keep-Awake Timers:** 
  - Presets: `15m`, `30m`, `45m`, `1h`, `2h`, `4h`, `8h`, `Indefinite (∞)`
  - Extensions: `+15m`, `+30m`, `+45m`, `+1h`, `+2h`, `Custom...`
- 🛡️ **Triple Hardware Safety Shields:**
  - **Low Battery Cutoff:** Automatically disengages if battery drops below a user-selected threshold (`5%`, `10%`, `15%`, `20%`, or custom).
  - **AC Power Only Mode:** Keeps awake only while connected to power; automatically restores sleep if unplugged.
  - **Thermal Guard:** Continuously monitors macOS thermal state (`serious`/`critical`) and yields to sleep if your Mac runs too hot.
- 🚀 **Universal Launch & Accessibility:**
  - Launch from Spotlight or Launchpad at any time.
  - Single-instance protection with automatic menu reveal on re-launch.
  - Optional Dock icon toggle (`Preferences > Show App Icon in Dock`).
  - Optional Start at Login LaunchAgent integration.
  - In-app feedback and bug report shortcut.

---

## 📸 Menu Interface & Dashboard

<div align="center">
  <p>
    <img src="GhostMode_Inactive.png" alt="Ghost Mode - Normal Sleep State" width="310" style="border-radius: 12px; margin-right: 12px;" />
    <img src="GhostMode_Active.png" alt="Ghost Mode - Active Session State" width="310" style="border-radius: 12px;" />
  </p>
  <p><i>Left: Normal Sleep (Inactive) &bull; Right: Active Keep-Awake Session with Live Progress</i></p>
</div>

---

## 🛠️ Building From Source

### Prerequisites
* macOS 12.0 (Monterey) or later
* Xcode Command Line Tools (`xcode-select --install`)
* Git

### 1. Clone the Repository
```bash
git clone https://github.com/malikarpit/Ghost-Mode.git
cd Ghost-Mode
```

### 2. Build and Install Directly to `/Applications`:
```bash
make install
```

### 3. (Optional) Build Drag-and-Drop `.dmg` Installer:
```bash
make dmg
```
This generates `GhostMode-Installer.dmg` in the project root.

### 4. Uninstall:
```bash
make uninstall
```

---

## 🔐 Privilege Configuration (Passwordless Sudo)

Managing macOS clamshell sleep behavior via `pmset` requires administrator privileges. Ghost Mode includes a secure setup helper that configures a scoped sudoers rule allowing only `/usr/bin/pmset` without repeated password prompts:

- **Via App Interface (Easiest):**  
  Click **Preferences > Setup Passwordless Sudo...** inside Ghost Mode.
- **Via Terminal:**  
  ```bash
  sudo ./ghostmode_setup.sh
  ```

---

## 🐛 Bug Reports & Feature Requests

Have a feature suggestion or encountered a bug?
- **In-App:** Click the menu bar icon ➡️ **Feedback & Bug Reports...**
- **On GitHub:** Open an issue on our [**Issue Tracker**](https://github.com/malikarpit/Ghost-Mode/issues/new/choose).

---

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct and the development process.

---

## 🏗️ Architecture

- **Universal 2 Binary**: Natively compiled for both **Apple Silicon (M1/M2/M3/M4)** and **Intel 64-bit (`x86_64`)**.
- **In-Memory Timer Loop**: Attached to `RunLoop.Mode.common` so the UI never pauses while opening menus.
- **Subprocess Efficiency**: Subprocesses are kept to a minimum with cached privilege queries and native IOKit clamshell sensors.
- **Single Instance Enforcement**: Uses atomic POSIX advisory file locking (`flock`) combined with `NSRunningApplication` PID detection.

---

## 📄 License & Ownership

Developed and maintained by **Arpit**.  
Copyright © 2026 Arpit. All rights reserved.

Distributed under the [MIT License](LICENSE).
