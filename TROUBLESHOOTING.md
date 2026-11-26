# Troubleshooting Ghost Mode

Quick fixes for installation, Gatekeeper, closed-lid sleep/lock behavior, audio rules, and diagnostics.

---

## 1. Installation & Gatekeeper

### macOS says "Apple could not verify Ghost Mode" or "Ghost Mode is damaged"

Community releases are ad-hoc signed without an Apple Developer ID notarization fee, so macOS quarantines downloads from a browser.

**Fastest fix (after dragging `Ghost Mode.app` into `/Applications`):**

```bash
xattr -cr "/Applications/Ghost Mode.app"
```

Then open **Ghost Mode** normally from `/Applications` or Spotlight.

**Without Terminal:**
1. Double-click **Ghost Mode.app** in `/Applications` once and dismiss the warning.
2. Open **System Settings &rarr; Privacy & Security**, scroll down, and click **Open Anyway**.

**Optional integrity check:**
```bash
shasum -a 256 -c GhostMode-Installer.dmg.sha256
codesign --verify --deep --strict "/Applications/Ghost Mode.app"
```

---

## 2. Password Prompt When Opening the Lid

### "I closed the lid with Ghost Mode active, and macOS asked for my password when I opened it."

In most cases, **your Mac did not sleep**—macOS **Lock Screen** locked the display after your configured inactivity delay once the screen turned off.

1. Check if the Mac stayed awake and see your current lock delay:
   ```bash
   pmset -g live | grep SleepDisabled
   pmset -g assertions | grep GhostMode
   sysadminctl -screenLock status
   ```
   If `SleepDisabled` is `1` and `GhostMode` holds `PreventUserIdleSystemSleep`, the system stayed awake underneath.
2. Adjust when macOS asks for a password:
   Open **System Settings &rarr; Lock Screen &rarr; Require password after screen saver begins or display is turned off** and raise the delay (or use Touch ID / Apple Watch unlock).

---

## 3. Passwordless Sudo & Closed-Lid Controls

### "Turn Off Screen on Lid Close" or "Freeze Apps on Lid Close" is disabled

Ghost Mode disables closed-lid automation switches when passwordless `sudo` for `/usr/bin/pmset` is not configured.

1. Click the menu bar ghost &rarr; **Settings &rarr; Passwordless Sudo &rarr; Setup...** and enter your admin password once.
2. Or configure via Terminal from the cloned repository:
   ```bash
   sudo ./ghostmode_setup.sh
   ```
3. Verify it works without prompting:
   ```bash
   sudo -n /usr/bin/pmset -g
   ```

> **Note:** If you move or re-build `/Applications/Ghost Mode.app` with an invalid signature, `SecCode` verification blocks elevation. Reinstall cleanly and run `codesign --verify --deep --strict "/Applications/Ghost Mode.app"`.

---

## 4. Sleep Not Restored (`Sleep Restore Pending`)

### Normal sleep didn't return after a session stopped behind a closed lid

If passwordless `sudo` wasn't configured and a battery/thermal/timer cutoff triggered while the lid was closed, Ghost Mode enters **Sleep Restore Pending** rather than popping an unseen password prompt behind a shut screen.

- **In App:** Open the lid and approve the prompt or click **Restore Normal Sleep**.
- **Manual Terminal reset:**
  ```bash
  sudo /usr/bin/pmset disablesleep 0
  pmset -g live | grep SleepDisabled
  ```
  `SleepDisabled` should read `0`.

---

## 5. Frozen Apps & Audio Rules

### An app stayed paused after opening the lid or quitting Ghost Mode

Ghost Mode automatically sends `SIGCONT` on lid open, stop, quit, crash recovery, and macOS emergency sleep. If a process still looks paused:

1. Right-click the menu bar ghost &rarr; **Unfreeze All** (or open the popover &rarr; **Unfreeze All**).
2. Or resume manually by PID:
   ```bash
   kill -CONT <PID>
   ```
3. Add permanent exceptions under **Safety &rarr; App Whitelist** so Ghost Mode never pauses that app.

### An audio app got paused when closing the lid

1. Open **Safety &rarr; Audio App Rules**:
   - In **Only Selected**, make sure the app (browser or player) is checked.
   - In **All Except Blocked**, make sure it isn't blocked.
2. Note that some web/Electron players take a second to register a CoreAudio stream when playback starts—open-source WebKit/Chromium renderers map back to their parent browser automatically once audio output is active.

---

## 6. Notifications & Stale Cached Icon

### Notifications don't appear

1. Open **System Settings &rarr; Notifications &rarr; Ghost Mode** and enable **Allow Notifications**.
2. Make sure the app is installed as a `.app` bundle (`/Applications/Ghost Mode.app`), not run as a bare binary.

### Notification Center still shows an older cached icon after updating

macOS `iconservicesd` caches app icons by bundle identifier in a system-protected store. To force an immediate reload without rebooting:

```bash
sudo rm -rf /Library/Caches/com.apple.iconservices.store && sudo killall iconservicesd iconservicesagent NotificationCenter usernoted
```

---

## 7. Uninstall Cleanly

```bash
# If cloned locally:
make uninstall

# Or manually:
sudo /usr/bin/pmset disablesleep 0
sudo rm -f /private/etc/sudoers.d/ghostmode
rm -rf "/Applications/Ghost Mode.app" ~/Library/Application\ Support/GhostMode
```

---

## Still Stuck?

Open **Ghost Mode &rarr; Settings &rarr; Copy Diagnostics** and attach the snapshot in a [GitHub Bug Report](https://github.com/malikarpit/Ghost-Mode/issues/new?template=bug_report.yml).
