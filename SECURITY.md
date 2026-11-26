# Security Policy

[&larr; Back to README](README.md)

---

## Supported Versions

| Version | Supported | Security Updates |
| --- | --- | --- |
| **2.1.x** | Yes | Active |
| **< 2.1** | No | End of life (upgrade to 2.1.x) |

---

## Privilege & Isolation Model

Because Ghost Mode interfaces with macOS power management (`pmset disablesleep`) and user-space process suspension (`SIGSTOP` / `SIGCONT`), its architecture enforces strict boundaries around privilege elevation and target selection.

### 1. Administrator Elevation (`Setup` & `Revoke`)

- **Closed Action Boundary**: All administrator-privileged execution passes through `PowerManager.performPrivilegedAction(_:)` using a closed `PrivilegedAction` enum:
  - `.configurePasswordlessSudo(username:)`
  - `.revokePasswordlessSudo`
  - `.setLidSleepDisabled(Bool)`
  AppleScript elevation is strictly `private`—no public arbitrary shell-command execution API exists.
- **No Mutable Disk Script in GUI Flow**: GUI **Setup** constructs its validated root payload from compiled constants rather than executing the writable `Contents/Resources/ghostmode_setup.sh` script on disk.
- **Runtime Code-Signature Verification**: Before any elevation prompt runs, `verifyBundleCodeSignature()` validates:
  1. The running dynamic process (`SecCodeCopySelf` + `SecCodeCheckValidity`) and signing identifier (`com.arpit.GhostMode`).
  2. The on-disk app bundle (`SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode`).
  Tampered executables, modified `Info.plist` entries, or altered bundle resources fail verification and block elevation.
- **Kernel-Verified Identity & Strict Validation**: Account username is obtained directly from the kernel UID (`getpwuid(getuid())`) and checked against `^[a-zA-Z0-9._-]+$` (max 64 chars; rejects empty strings, `root`, `loginwindow`, `_mbsetupuser`, and leading `-` or `.`), ignoring `$USER` and `$SUDO_USER` in GUI elevation.
- **Least-Privilege Rule & Anti-TOCTOU Staging**:
  - Generated `/private/etc/sudoers.d/ghostmode` permits only exact `pmset` subcommands:
    ```sudoers
    Cmnd_Alias GHOSTMODE_PMSET = /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -g
    ```
  - Staging uses a `0700 root:wheel` directory created inside `0750 root:wheel` `/private/etc/sudoers.d` (eliminating `/tmp` / `$TMPDIR` race windows), locked `PATH`, `umask 077`, symlink/directory rejection, and `/usr/sbin/visudo -cf` syntax validation prior to atomic `mv` and `0440 root:wheel` permissions.
  - **Revoke** safely removes `/private/etc/sudoers.d/ghostmode`.

### 2. App Freeze Safeguards (`SIGSTOP` / `SIGCONT`)

- **UID & Core-System Immunity**: Only targets processes owned by the current user (`pbi_uid == getuid()`), skipping PIDs `<= 100`, zombie processes (`SZOMB`), Ghost Mode itself, and all ancestor/responsible PIDs of Ghost Mode.
- **Core OS Protection**: Never freezes essential macOS daemons/shells (`Finder`, `Dock`, `WindowManager`, `ControlCenter`, `SystemUIServer`, `Spotlight`, `loginwindow`, `SecurityAgent`, `UserNotificationCenter`, `CoreServicesUIAgent`, `OSDUIHelper`, `coreaudiod`, `bluetoothd`, `airportd`, `com.apple.security.*`) or core executable directories (`/bin/`, `/sbin/`, `/usr/bin/`, `/usr/sbin/`, `/usr/libexec/`, `/System/Library/`, `/Library/Apple/`, and Cryptex equivalents).
- **Deadlock Prevention & Crash Recovery**: Freezes child helpers before main `.regular` parent apps, resumes main `.regular` parent apps before child helpers, verifies `(pid, startSec, startUsec, SSTOP)` before sending `SIGCONT` (preventing PID reuse hazards), persists frozen records (`frozen_pids.json`) for orphan recovery on launch, and maintains an async-signal-safe pre-allocated C table (`fatalCrashSignalHandler`) so fatal signals unfreeze tracked PIDs.

---

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

1. Report privately via [**GitHub Security Advisories**](https://github.com/malikarpit/Ghost-Mode/security/advisories/new).
2. Include your macOS version, chip architecture (`arm64` / `x86_64`), Ghost Mode version (**Settings &rarr; Copy Diagnostics**), and reproduction steps or proof of concept.

### Response Commitment

| Milestone | Target |
| --- | --- |
| Initial acknowledgement | Within 48 hours |
| Triage & root-cause validation | Coordinated via private advisory |
| Fix & public disclosure | Released together with advisory notes |
