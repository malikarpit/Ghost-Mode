# Contributing to Ghost Mode

[&larr; Back to README](README.md) &middot; [Security Policy](SECURITY.md) &middot; [Code of Conduct](CODE_OF_CONDUCT.md)

Thank you for helping improve **Ghost Mode**! Bug fixes, hardware/audio edge-case improvements, UI refinements, documentation updates, and tests are all welcome.

---

## Development Setup

### Prerequisites

| Requirement | Notes |
| --- | --- |
| **macOS** | 12.0+ (Apple Silicon) &middot; 14.0+ (Intel via CLT) &middot; 26.0+ recommended for Liquid Glass testing |
| **Toolchain** | Apple Command Line Tools (`xcode-select --install`) or full Xcode |
| **Dependencies** | None &mdash; pure native macOS frameworks only |

### Build, Test & Package Commands

```bash
git clone https://github.com/malikarpit/Ghost-Mode.git
cd Ghost-Mode

# Validate shell scripts
bash -n ghostmode_setup.sh make_icns.sh

# Clean build of Universal 2 Ghost Mode.app (arm64 + x86_64)
make clean && make all

# Run the native unit test suite
make test

# Install to /Applications/Ghost Mode.app
make install

# Package GhostMode-Installer.dmg
make dmg
```

---

## Project Architecture & Module Map

| File | Responsibility |
| --- | --- |
| [Sources/main.swift](Sources/main.swift) | POSIX `flock` single-instance lock & `NSApplication` startup |
| [Sources/Models.swift](Sources/Models.swift) | Session state, snapshots, `SavedRuleEntry`, `SudoersPolicy`, `PrivilegedAction`, `SudoFeatureAvailability` |
| [Sources/Preferences.swift](Sources/Preferences.swift) | `UserDefaults` persistence for Ghost Mode preferences |
| [Sources/DurationHelpers.swift](Sources/DurationHelpers.swift) | Duration string parsing (`90m`, `1.5h`) & countdown formatting |
| [Sources/PowerManager.swift](Sources/PowerManager.swift) | IOKit sleep/display assertions, `pmset` queries, `SecCode` bundle verification, hardened elevation |
| [Sources/DisplayManager.swift](Sources/DisplayManager.swift) | IOKit `AppleClamshellState` queries & `pmset displaysleepnow` / `IODisplayWrangler` sleep |
| [Sources/AppFreezer.swift](Sources/AppFreezer.swift) | `CoreAudio` + `IOPMAssertions` detection, Cryptex normalization, `responsiblePid`, deadlock-safe `SIGSTOP`/`SIGCONT` |
| [Sources/SafetyControllers.swift](Sources/SafetyControllers.swift) | Debounced AC/Battery evaluator, thermal hysteresis guard, `SystemPowerSleepMonitor` |
| [Sources/NotificationService.swift](Sources/NotificationService.swift) | UserNotifications wrapper with graceful fallback when headless or unbundled |
| [Sources/ProcessDiagnostics.swift](Sources/ProcessDiagnostics.swift) | Mach `task_info` CPU & physical memory footprint telemetry |
| [Sources/SignalAndLogin.swift](Sources/SignalAndLogin.swift) | Graceful signal handling, crash unfreeze handler & `SMAppService` / LaunchAgent login items |
| [Sources/AppDelegate.swift](Sources/AppDelegate.swift) | Event monitoring, IOKit observers, session/freeze reconciliation, diagnostics export |
| [Sources/GhostModeViewModel.swift](Sources/GhostModeViewModel.swift) | `@MainActor` UI state, saved-rule LaunchServices resolution, preference actions |
| [Sources/PopoverViews.swift](Sources/PopoverViews.swift) | `Session`, `Safety`, `Settings`, `App Whitelist`, & `Audio App Rules` SwiftUI views |
| [Sources/StatusBarController.swift](Sources/StatusBarController.swift) | Full-Screen-capable `NSPanel`, `NSGlassEffectView` / `NSVisualEffectView`, top-anchored resize animation |
| [Tests/GhostModeTests.swift](Tests/GhostModeTests.swift) | Self-contained native unit test runner (`make test`) |

---

## Engineering & Compatibility Standards

- **Zero Compiler Warnings**: Every PR must pass `make clean && make all && make test` cleanly with zero warnings or errors.
- **macOS Compatibility**: Guard macOS 13+, 14+, and 26+ APIs cleanly (`@available` / `#available`) and avoid SwiftUI macro attributes (`@State` / `@FocusState` macros that require `SwiftUIMacros.dylib` absent in standalone Command Line Tools builds); keep UI state in `ObservableObject` view state classes.
- **Security Invariants**: Route all privileged operations exclusively through `PowerManager.performPrivilegedAction(_:)` with `SudoersPolicy` validation; never introduce raw command string helpers or `$TMPDIR`-based staging.
- **Process Safety**: Keep core OS daemons, commands (`/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/libexec`, `/System/Library`, `/Library/Apple` + Cryptex), and Ghost Mode ancestors immune from freezing, and always resume parents before helpers.

---

## Pull Request Workflow

1. Fork the repository and branch from `main` (`fix/...`, `feat/...`, `docs/...`).
2. Add or update unit tests in [Tests/GhostModeTests.swift](Tests/GhostModeTests.swift) covering new behavior or invariants.
3. Verify locally:
   ```bash
   bash -n ghostmode_setup.sh make_icns.sh && make clean && make dmg && make test
   codesign --verify --deep --strict --verbose=2 "Ghost Mode.app"
   ```
4. Open a PR using the [PR Template](.github/PULL_REQUEST_TEMPLATE.md).

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
