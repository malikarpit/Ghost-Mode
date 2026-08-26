//
//  main.swift
//  Ghost Mode (macOS Keep-Awake & Display Controller)
//
//  Created & Developed by Arpit
//  Copyright © 2026 Arpit. All rights reserved.
//  Digital Identifier: com.arpit.GhostMode
//

import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - App Metadata & Signature
struct AppMetadata {
    static let name = "Ghost Mode"
    static let version = "1.0"
    static let author = "Arpit"
    static let copyright = "Copyright © 2026 Arpit. All rights reserved."
    static let digitalSignature = "Signed by Arpit (com.arpit.GhostMode)"
    static let summary = "Keep your Mac running with the lid closed, instantly power down the display to eliminate heat and conserve battery, and set customizable keep-awake timers."
    static let githubRepoURL = "https://github.com/malikarpit/Ghost-Mode"
    static let issuesURL = "https://github.com/malikarpit/Ghost-Mode/issues"
    static let reportURL = "https://github.com/malikarpit/Ghost-Mode/issues/new/choose"
}

// MARK: - Universal Single-Instance Enforcement
var globalLockFileDescriptor: Int32 = -1

func enforceSingleInstance() -> Bool {
    let currentPid = getpid() // Dynamically assigned OS process ID for current process

    // 1. Inspect running instances of Ghost Mode across active processes
    let identifiers = ["com.arpit.GhostMode", "com.arpit.LidSentry"]
    for id in identifiers {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        for app in runningApps {
            if app.processIdentifier != currentPid {
                print("Ghost Mode: Existing instance detected (PID \(app.processIdentifier)). Notifying running app.")
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.arpit.ghostmode.showMenu"),
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                return false
            }
        }
    }

    // 2. User-specific atomic POSIX file lock in the user's isolated temporary directory
    let tempDir = FileManager.default.temporaryDirectory
    let lockURL = tempDir.appendingPathComponent("ghostmode_\(getuid()).lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    if fd < 0 { return true }

    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        print("Ghost Mode: Active lock on \(lockURL.path). Existing instance running.")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.arpit.ghostmode.showMenu"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        close(fd)
        return false
    }

    globalLockFileDescriptor = fd
    return true
}

// MARK: - Preferences Manager
class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let defaultDuration = "defaultDuration"
        static let turnOffScreenOnLidClose = "turnOffScreenOnLidClose"
        static let batteryCutoffThreshold = "batteryCutoffThreshold"
        static let batteryCutoffEnabled = "batteryCutoffEnabled"
        static let acOnlyModeEnabled = "acOnlyModeEnabled"
        static let thermalGuardEnabled = "thermalGuardEnabled"
        static let showCountdownInMenuBar = "showCountdownInMenuBar"
        static let soundNotificationsEnabled = "soundNotificationsEnabled"
        static let showInDock = "showInDock"
        static let hasSeenWelcome = "hasSeenWelcome"
    }

    var defaultDuration: Int {
        get {
            let val = defaults.integer(forKey: Keys.defaultDuration)
            return val > 0 ? val : 3600 // Default: 1 hour (3600s)
        }
        set { defaults.set(newValue, forKey: Keys.defaultDuration) }
    }

    var turnOffScreenOnLidClose: Bool {
        get {
            if defaults.object(forKey: Keys.turnOffScreenOnLidClose) == nil { return true }
            return defaults.bool(forKey: Keys.turnOffScreenOnLidClose)
        }
        set { defaults.set(newValue, forKey: Keys.turnOffScreenOnLidClose) }
    }

    var batteryCutoffThreshold: Int {
        get {
            if defaults.object(forKey: Keys.batteryCutoffThreshold) == nil { return 10 } // Default: 10%
            return defaults.integer(forKey: Keys.batteryCutoffThreshold)
        }
        set { defaults.set(newValue, forKey: Keys.batteryCutoffThreshold) }
    }

    var batteryCutoffEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.batteryCutoffEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.batteryCutoffEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.batteryCutoffEnabled) }
    }

    var acOnlyModeEnabled: Bool {
        get { return defaults.bool(forKey: Keys.acOnlyModeEnabled) }
        set { defaults.set(newValue, forKey: Keys.acOnlyModeEnabled) }
    }

    var thermalGuardEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.thermalGuardEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.thermalGuardEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.thermalGuardEnabled) }
    }

    var showCountdownInMenuBar: Bool {
        get {
            if defaults.object(forKey: Keys.showCountdownInMenuBar) == nil { return true }
            return defaults.bool(forKey: Keys.showCountdownInMenuBar)
        }
        set { defaults.set(newValue, forKey: Keys.showCountdownInMenuBar) }
    }

    var soundNotificationsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.soundNotificationsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.soundNotificationsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.soundNotificationsEnabled) }
    }

    var showInDock: Bool {
        get { return defaults.bool(forKey: Keys.showInDock) }
        set { defaults.set(newValue, forKey: Keys.showInDock) }
    }

    var hasSeenWelcome: Bool {
        get { return defaults.bool(forKey: Keys.hasSeenWelcome) }
        set { defaults.set(newValue, forKey: Keys.hasSeenWelcome) }
    }
}

// MARK: - Display & Hardware Manager (MacBook + Desktop Macs)
class DisplayManager {
    static let shared = DisplayManager()

    func hasLid() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        let prop = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return prop != nil
    }

    func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        if let prop = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return prop
        }
        return false
    }

    func turnOffDisplay() {
        print("DisplayManager: Requesting display sleep for Ghost Mode by Arpit...")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IODisplayWrangler"))
        if service != IO_OBJECT_NULL {
            IORegistryEntrySetCFProperty(service, "IORequestIdle" as CFString, kCFBooleanTrue)
            IOObjectRelease(service)
        }

        // Backup command for Apple Silicon / Intel power management
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }
}

// MARK: - Notification Helper
class NotificationHelper {
    static func send(title: String, subtitle: String? = nil, message: String) {
        var script = "display notification \"\(message.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
        if let sub = subtitle, !sub.isEmpty {
            script += " subtitle \"\(sub.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        if Preferences.shared.soundNotificationsEnabled {
            script += " sound name \"default\""
        }
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
    }
}

// MARK: - Duration Helpers
func parseDurationString(_ input: String) -> Int? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.isEmpty { return nil }

    var totalSeconds = 0
    var matched = false

    let hourRegex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:h|hr|hours?)"#)
    if let match = hourRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let r = Range(match.range(at: 1), in: text), let h = Double(text[r]) {
            totalSeconds += Int(h * 3600)
            matched = true
        }
    }

    let minRegex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:m|min|mins|minutes?)"#)
    if let match = minRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let r = Range(match.range(at: 1), in: text), let m = Double(text[r]) {
            totalSeconds += Int(m * 60)
            matched = true
        }
    }

    let secRegex = try? NSRegularExpression(pattern: #"([0-9]+)\s*(?:s|sec|seconds?)"#)
    if let match = secRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let r = Range(match.range(at: 1), in: text), let s = Int(text[r]) {
            totalSeconds += s
            matched = true
        }
    }

    if !matched {
        if let num = Double(text) {
            return Int(num * 60)
        }
    }
    return matched ? totalSeconds : nil
}

func formatDurationHuman(_ seconds: Int) -> String {
    if seconds <= 0 { return "Indefinite" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 && m > 0 {
        return "\(h)h \(m)m"
    } else if h > 0 {
        return "\(h)h"
    } else if m > 0 && s > 0 && seconds < 300 {
        return "\(m)m \(s)s"
    } else if m > 0 {
        return "\(m)m"
    } else {
        return "\(s)s"
    }
}

func formatCountdown(_ seconds: Int) -> String {
    if seconds <= 0 { return "00:00" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 {
        return String(format: "%dh %02dm %02ds", h, m, s)
    } else {
        return String(format: "%02d:%02d", m, s)
    }
}

func formatDurationCompact(_ seconds: Int) -> String {
    if seconds <= 0 { return "0s" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 && m > 0 {
        return "\(h)h \(m)m"
    } else if h > 0 {
        return "\(h)h"
    } else if m > 0 {
        return "\(m)m"
    } else {
        return "\(s)s"
    }
}

// MARK: - Power Manager
class PowerManager {
    static let shared = PowerManager()
    private var caffeinateProcess: Process?

    func shell(_ command: String) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        } catch {
            return (error.localizedDescription, -1)
        }
    }

    func checkLidSleepDisabled() -> Bool {
        let (output, _) = shell("/usr/bin/pmset -g")
        return output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    func isPasswordlessSudoConfigured() -> Bool {
        let (_, exitCode) = shell("sudo -n /usr/bin/pmset -g")
        return exitCode == 0
    }

    func runSudoCommandWithAppleScript(command: String) -> Bool {
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "do shell script \"\(escapedCommand)\" with administrator privileges"
        if let script = NSAppleScript(source: scriptSource) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    func setLidSleep(disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        let sudoConfigured = isPasswordlessSudoConfigured()

        var success = false
        if sudoConfigured {
            let (_, exitCode) = shell("sudo /usr/bin/pmset disablesleep \(value)")
            success = (exitCode == 0)
        } else {
            success = runSudoCommandWithAppleScript(command: "/usr/bin/pmset disablesleep \(value)")
        }

        if success {
            if disabled {
                startCaffeinateBackground()
            } else {
                stopCaffeinateBackground()
            }
        }
        return success
    }

    func startCaffeinateBackground() {
        guard caffeinateProcess == nil || !caffeinateProcess!.isRunning else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-ims"]
        do {
            try process.run()
            caffeinateProcess = process
        } catch {
            print("Failed to start background caffeinate: \(error)")
        }
    }

    func stopCaffeinateBackground() {
        if let process = caffeinateProcess, process.isRunning {
            process.terminate()
            caffeinateProcess = nil
        }
    }

    func getBatteryStatus() -> (percent: Int, isCharging: Bool, isAC: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
                let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
                let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
                let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
                let isAC = (powerSourceState == kIOPSACPowerValue as String)
                let percent = max > 0 ? (current * 100) / max : current
                return (percent, isCharging, isAC)
            }
        }
        return nil
    }
}

// MARK: - Dashboard Header (custom view for the top of the menu)
// A single NSView-based menu item replaces the old two plain-text rows.
// Using a real view (instead of NSMenuItem.title) buys two things:
//  1. It can hold real controls (buttons), so the most common actions
//     don't require opening a submenu.
//  2. It redraws live while the menu is open, unlike a text-only item.
final class ProgressBarView: NSView {
    /// 0.0 ... 1.0. Values outside that range are clamped.
    var progress: CGFloat = 1.0 { didSet { needsLayout = true } }
    var fillColor: NSColor = .systemGreen { didSet { fillLayer.backgroundColor = fillColor.cgColor } }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        trackLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fillLayer.backgroundColor = fillColor.cgColor
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        trackLayer.frame = bounds
        trackLayer.cornerRadius = radius
        let clamped = max(0, min(1, progress))
        fillLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        fillLayer.cornerRadius = radius
    }
}

final class DashboardHeaderView: NSView {
    // Match this to whatever width your widest existing menu row renders at
    // (e.g. "🛑 Stop Ghost Mode (Allow Sleep)") so the dashboard doesn't look
    // narrower or wider than the rest of the menu. 260 is a starting point —
    // tune it visually in Xcode's preview.
    private static let viewWidth: CGFloat = 260
    private static let viewHeight: CGFloat = 100

    private let iconView = NSImageView(frame: NSRect(x: 14, y: 78, width: 18, height: 18))
    private let titleLabel = NSTextField(labelWithString: "Ghost Mode")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = ProgressBarView(frame: NSRect(x: 14, y: 66, width: 232, height: 5))
    private let detailLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(frame: .zero)
    private let secondaryButton = NSButton(frame: NSRect(x: 135, y: 18, width: 111, height: 24))

    /// Turn On (when idle) / Stop (when active).
    var onPrimaryTap: (() -> Void)?
    /// +30 min. Only shown while active.
    var onSecondaryTap: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func build() {
        titleLabel.frame = NSRect(x: 38, y: 79, width: 90, height: 16)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        statusLabel.frame = NSRect(x: 14, y: 79, width: 232, height: 16)
        statusLabel.alignment = .right
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        detailLabel.frame = NSRect(x: 14, y: 51, width: 140, height: 12)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor

        infoLabel.frame = NSRect(x: 106, y: 51, width: 140, height: 12)
        infoLabel.alignment = .right
        infoLabel.font = .systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor

        for label in [titleLabel, statusLabel, detailLabel, infoLabel] {
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.drawsBackground = false
            addSubview(label)
        }

        addSubview(iconView)
        addSubview(progressBar)

        primaryButton.bezelStyle = .rounded
        primaryButton.font = .systemFont(ofSize: 11)
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        addSubview(primaryButton)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.title = "+30m"
        secondaryButton.font = .systemFont(ofSize: 11)
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryTapped)
        addSubview(secondaryButton)
    }

    func configure(isActive: Bool,
                   isIndefinite: Bool,
                   remainingSeconds: Int?,
                   initialDurationSeconds: Int?,
                   defaultDuration: Int,
                   battery: (percent: Int, isCharging: Bool, isAC: Bool)?,
                   isLidClosed: Bool,
                   hasLid: Bool) {

        // Icon + status pill
        let iconName = isActive ? (hasLid && isLidClosed ? "moon.stars.fill" : "cup.and.saucer.fill") : "powersleep"
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = isActive ? .systemIndigo : .secondaryLabelColor

        if isActive {
            statusLabel.stringValue = isIndefinite ? "Active · ∞" : "Active"
            statusLabel.textColor = isIndefinite ? .systemOrange : .systemGreen
        } else {
            statusLabel.stringValue = "Normal Sleep"
            statusLabel.textColor = .secondaryLabelColor
        }

        // Progress bar + left-hand detail text
        if isActive, let remaining = remainingSeconds, let total = initialDurationSeconds, total > 0 {
            let fraction = CGFloat(remaining) / CGFloat(total)
            progressBar.isHidden = false
            progressBar.progress = fraction
            progressBar.fillColor = color(forRemainingFraction: fraction)
            detailLabel.stringValue = "\(formatCountdown(remaining)) left"
        } else if isActive {
            progressBar.isHidden = true
            detailLabel.stringValue = "Running indefinitely"
        } else {
            progressBar.isHidden = true
            detailLabel.stringValue = "Sleep behaves normally"
        }

        // Right-hand battery / lid text
        var info = ""
        if let bat = battery {
            let symbol = bat.isCharging ? "⚡" : (bat.isAC ? "🔌" : "🔋")
            info += "\(symbol) \(bat.percent)%"
        }
        if hasLid {
            info += info.isEmpty ? "" : "  ·  "
            info += isLidClosed ? "Lid closed" : "Lid open"
        }
        infoLabel.stringValue = info

        // Quick-action buttons: full-width "Turn On" when idle, "Stop" + "+30m" when active
        if isActive {
            primaryButton.title = "🛑 Stop"
            primaryButton.frame = NSRect(x: 14, y: 18, width: 111, height: 24)
            secondaryButton.isHidden = false
        } else {
            primaryButton.title = "👻 Turn On (\(formatDurationHuman(defaultDuration)))"
            primaryButton.frame = NSRect(x: 14, y: 18, width: 232, height: 24)
            secondaryButton.isHidden = true
        }
    }

    private func color(forRemainingFraction f: CGFloat) -> NSColor {
        if f > 0.5 { return .systemGreen }
        if f > 0.15 { return .systemOrange }
        return .systemRed
    }

    @objc private func primaryTapped() {
        onPrimaryTap?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    @objc private func secondaryTapped() {
        onSecondaryTap?()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

// MARK: - Session Stop Reasons
enum SessionStopReason {
    case userManual
    case timerExpired
    case lowBattery(percent: Int)
    case unpluggedAC
    case thermalOverheat
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var tickerTimer: Timer?

    // Session State
    var isKeepAwakeActive: Bool = false
    var sessionEndDate: Date?
    var isIndefiniteSession: Bool = false
    var activeInitialDurationSeconds: Int? = nil
    var lastLidClosedState: Bool = false
    var lastACState: Bool = true

    // Menu Components
    var menu = NSMenu()

    // 1. Sleek Dashboard Header
    var dashboardMenuItem: NSMenuItem!
    var dashboardView: DashboardHeaderView!
    var topSeparator: NSMenuItem!

    // 2. Extend submenu (dashboard's Stop/+30m buttons cover the single-tap cases now)
    var extendSubmenuItem: NSMenuItem!
    var extendSubmenu = NSMenu()

    // 3. Presets & Screen Controls
    var presetsSubmenuItem: NSMenuItem!
    var presetsSubmenu = NSMenu()
    var presetMenuItems: [(item: NSMenuItem, baseTitle: String, seconds: Int)] = []
    var customPresetMenuItem: NSMenuItem!

    var turnOffScreenItem: NSMenuItem!
    var screenOnLidCloseItem: NSMenuItem!
    var settingsSeparator: NSMenuItem!

    // 4. Safety & Preferences Submenus
    var safetySubmenuItem: NSMenuItem!
    var safetySubmenu = NSMenu()
    var lowBatterySubmenu = NSMenu()
    var preferencesSubmenuItem: NSMenuItem!
    var prefSubmenu = NSMenu()

    // Submenu references
    var lowBattery5Item: NSMenuItem!
    var lowBattery10Item: NSMenuItem!
    var lowBattery15Item: NSMenuItem!
    var lowBattery20Item: NSMenuItem!
    var lowBatteryOffItem: NSMenuItem!
    var lowBatteryCustomItem: NSMenuItem!

    var acOnlyItem: NSMenuItem!
    var thermalGuardItem: NSMenuItem!
    var showCountdownItem: NSMenuItem!
    var showInDockItem: NSMenuItem!
    var soundItem: NSMenuItem!
    var setupSudoItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var defaultDurationItem: NSMenuItem!
    var aboutItem: NSMenuItem!
    var reportBugItem: NSMenuItem!
    var viewGitHubItem: NSMenuItem!
    var developerCreditItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Ghost Mode v\(AppMetadata.version) by \(AppMetadata.author): Initialized successfully.")
        cleanupLegacyArtifacts()
        setupWatchdog()

        // Apply Dock visibility preference
        let showInDock = Preferences.shared.showInDock
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()

        lastLidClosedState = DisplayManager.shared.isLidClosed()
        if let bat = PowerManager.shared.getBatteryStatus() {
            lastACState = bat.isAC
        }

        let isSleepDisabled = PowerManager.shared.checkLidSleepDisabled()
        if isSleepDisabled {
            isKeepAwakeActive = true
            isIndefiniteSession = true
            activeInitialDurationSeconds = -1
        }

        updateStatusUI()

        tickerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerTick()
        }
        // NSMenu tracking runs the run loop in .eventTrackingRunLoopMode, not
        // .default, so a plain scheduledTimer silently pauses while the
        // dropdown is open. Add it to .common so the dashboard keeps ticking.
        if let timer = tickerTimer {
            RunLoop.current.add(timer, forMode: .common)
        }

        // Show welcome guidance on first launch
        if !Preferences.shared.hasSeenWelcome {
            Preferences.shared.hasSeenWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showWelcomeGuidance()
            }
        }

        let notificationName = Notification.Name("com.arpit.ghostmode.showMenu")
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(didReceiveShowMenuNotification(_:)),
            name: notificationName,
            object: nil
        )
    }

    func cleanupLegacyArtifacts() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let oldPlist = homeDir.appendingPathComponent("Library/LaunchAgents/com.arpit.lidsentry.plist")
        if fileManager.fileExists(atPath: oldPlist.path) {
            try? fileManager.removeItem(at: oldPlist)
        }
        let oldApp = URL(fileURLWithPath: "/Applications/LidSentry.app")
        if fileManager.fileExists(atPath: oldApp.path) {
            try? fileManager.removeItem(at: oldApp)
        }
    }

    func showWelcomeGuidance() {
        NotificationHelper.send(
            title: "👻 Ghost Mode (by \(AppMetadata.author))",
            subtitle: "Active in your Menu Bar",
            message: "Click the Ghost icon at the top right of your screen to set timers and manage closed-lid sleep!"
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem.button {
            button.performClick(nil)
        }
        return true
    }

    @objc func didReceiveShowMenuNotification(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem.button {
            button.performClick(nil)
        }
    }

    func setupWatchdog() {
        // Signal handler must ONLY call async-signal-safe functions (POSIX requirement).
        // Foundation's Process/NSTask spawns threads and is NOT async-signal-safe.
        // We use execv() directly — it replaces the current process image with pmset,
        // which is the only safe way to run a subprocess from a signal handler.
        let cleanExitHandler: @convention(c) (Int32) -> Void = { _ in
            // Restore normal sleep using execv (async-signal-safe)
            // This replaces the process with: /usr/bin/sudo /usr/bin/pmset disablesleep 0
            withUnsafePointer(to: UnsafePointer<CChar>(bitPattern: 0)) { _ in
                var args: [UnsafeMutablePointer<CChar>?] = [
                    strdup("/usr/bin/sudo"),
                    strdup("/usr/bin/pmset"),
                    strdup("disablesleep"),
                    strdup("0"),
                    nil
                ]
                execv("/usr/bin/sudo", &args)
            }
            // If execv fails (e.g. sudo not available), just exit cleanly
            _exit(0)
        }
        signal(SIGINT, cleanExitHandler)
        signal(SIGTERM, cleanExitHandler)
        signal(SIGHUP, cleanExitHandler)
    }


    func applicationWillTerminate(_ notification: Notification) {
        print("Ghost Mode: Application terminating.")
        PowerManager.shared.stopCaffeinateBackground()
        if PowerManager.shared.isPasswordlessSudoConfigured() {
            _ = PowerManager.shared.shell("sudo /usr/bin/pmset disablesleep 0")
        }
        if globalLockFileDescriptor >= 0 {
            flock(globalLockFileDescriptor, LOCK_UN)
            close(globalLockFileDescriptor)
        }
    }

    // MARK: - Menu Setup
    func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false

        // 1. Sleek Dashboard Header (custom view: icon, status, progress bar, quick actions)
        dashboardView = DashboardHeaderView()
        dashboardView.onPrimaryTap = { [weak self] in
            guard let self = self else { return }
            if self.isKeepAwakeActive {
                self.stopKeepAwakeSession(reason: .userManual)
            } else {
                self.startKeepAwakeSession(durationSeconds: Preferences.shared.defaultDuration)
            }
        }
        dashboardView.onSecondaryTap = { [weak self] in
            self?.extendSession(by: 30 * 60)
        }

        dashboardMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dashboardMenuItem.view = dashboardView // must stay enabled (default) so the buttons inside remain clickable
        menu.addItem(dashboardMenuItem)

        topSeparator = NSMenuItem.separator()
        menu.addItem(topSeparator)

        // 2. Extend Submenu — the dashboard's Stop/+30m buttons handle the
        // single-tap cases; this covers the finer-grained options (+15/45/1h/2h/custom).
        extendSubmenu = NSMenu()
        extendSubmenu.autoenablesItems = false

        let ext15 = NSMenuItem(title: "+15 Minutes", action: #selector(extend15MinClicked(_:)), keyEquivalent: "")
        ext15.target = self
        extendSubmenu.addItem(ext15)

        let ext30 = NSMenuItem(title: "+30 Minutes", action: #selector(extend30MinClicked(_:)), keyEquivalent: "")
        ext30.target = self
        extendSubmenu.addItem(ext30)

        let ext45 = NSMenuItem(title: "+45 Minutes", action: #selector(extend45MinClicked(_:)), keyEquivalent: "")
        ext45.target = self
        extendSubmenu.addItem(ext45)

        let ext1h = NSMenuItem(title: "+1 Hour", action: #selector(extend1HourClicked(_:)), keyEquivalent: "")
        ext1h.target = self
        extendSubmenu.addItem(ext1h)

        let ext2h = NSMenuItem(title: "+2 Hours", action: #selector(extend2HourClicked(_:)), keyEquivalent: "")
        ext2h.target = self
        extendSubmenu.addItem(ext2h)

        extendSubmenu.addItem(NSMenuItem.separator())
        let extCustom = NSMenuItem(title: "Custom Extension...", action: #selector(extendCustomClicked(_:)), keyEquivalent: "")
        extCustom.target = self
        extendSubmenu.addItem(extCustom)

        extendSubmenuItem = NSMenuItem(title: "Extend More...", action: nil, keyEquivalent: "")
        extendSubmenuItem.submenu = extendSubmenu
        menu.addItem(extendSubmenuItem)

        // 3. Start Session for... Presets Submenu
        presetsSubmenu = NSMenu()
        presetsSubmenu.autoenablesItems = false
        presetMenuItems.removeAll()

        let durations: [(String, Int)] = [
            ("15 Minutes", 15 * 60),
            ("30 Minutes", 30 * 60),
            ("45 Minutes", 45 * 60),
            ("1 Hour", 60 * 60),
            ("2 Hours", 2 * 3600),
            ("4 Hours", 4 * 3600),
            ("8 Hours", 8 * 3600),
            ("Indefinite (No Timer)", -1)
        ]

        for (name, secs) in durations {
            let item = NSMenuItem(title: name, action: #selector(startPresetSessionClicked(_:)), keyEquivalent: "")
            item.representedObject = secs
            item.target = self
            presetsSubmenu.addItem(item)
            presetMenuItems.append((item: item, baseTitle: name, seconds: secs))
        }

        presetsSubmenu.addItem(NSMenuItem.separator())
        customPresetMenuItem = NSMenuItem(title: "Custom Duration...", action: #selector(startCustomDurationClicked(_:)), keyEquivalent: "")
        customPresetMenuItem.target = self
        presetsSubmenu.addItem(customPresetMenuItem)

        presetsSubmenuItem = NSMenuItem(title: "Start Session for...", action: nil, keyEquivalent: "")
        presetsSubmenuItem.submenu = presetsSubmenu
        menu.addItem(presetsSubmenuItem)

        turnOffScreenItem = NSMenuItem(title: "Turn Off Screen Now 💤", action: #selector(turnOffScreenClicked(_:)), keyEquivalent: "")
        turnOffScreenItem.target = self
        menu.addItem(turnOffScreenItem)

        settingsSeparator = NSMenuItem.separator()
        menu.addItem(settingsSeparator)

        // 4. Screen, Safety & Preferences
        screenOnLidCloseItem = NSMenuItem(title: "Turn Off Screen on Lid Close", action: #selector(toggleScreenOnLidClose(_:)), keyEquivalent: "")
        screenOnLidCloseItem.target = self
        menu.addItem(screenOnLidCloseItem)

        // Safety Submenu
        safetySubmenu = NSMenu()
        safetySubmenu.autoenablesItems = false

        lowBatterySubmenu = NSMenu()
        lowBatterySubmenu.autoenablesItems = false

        lowBatteryOffItem = NSMenuItem(title: "Off (Disabled)", action: #selector(setBatteryCutoff(_:)), keyEquivalent: "")
        lowBatteryOffItem.representedObject = 0
        lowBatteryOffItem.target = self
        lowBatterySubmenu.addItem(lowBatteryOffItem)

        let thresholds: [(String, Int)] = [("5%", 5), ("10%", 10), ("15%", 15), ("20%", 20)]
        for (label, val) in thresholds {
            let item = NSMenuItem(title: label, action: #selector(setBatteryCutoff(_:)), keyEquivalent: "")
            item.representedObject = val
            item.target = self
            if val == 5 { lowBattery5Item = item }
            if val == 10 { lowBattery10Item = item }
            if val == 15 { lowBattery15Item = item }
            if val == 20 { lowBattery20Item = item }
            lowBatterySubmenu.addItem(item)
        }
        lowBatterySubmenu.addItem(NSMenuItem.separator())
        lowBatteryCustomItem = NSMenuItem(title: "Custom %...", action: #selector(setCustomBatteryCutoffClicked(_:)), keyEquivalent: "")
        lowBatteryCustomItem.target = self
        lowBatterySubmenu.addItem(lowBatteryCustomItem)

        let lowBatteryHeader = NSMenuItem(title: "Low Battery Cutoff", action: nil, keyEquivalent: "")
        lowBatteryHeader.submenu = lowBatterySubmenu
        safetySubmenu.addItem(lowBatteryHeader)

        acOnlyItem = NSMenuItem(title: "Only Keep Awake on AC Power", action: #selector(toggleACOnlyMode(_:)), keyEquivalent: "")
        acOnlyItem.target = self
        safetySubmenu.addItem(acOnlyItem)

        thermalGuardItem = NSMenuItem(title: "Thermal Overheat Protection", action: #selector(toggleThermalGuard(_:)), keyEquivalent: "")
        thermalGuardItem.target = self
        safetySubmenu.addItem(thermalGuardItem)

        safetySubmenuItem = NSMenuItem(title: "Safety Protections", action: nil, keyEquivalent: "")
        safetySubmenuItem.submenu = safetySubmenu
        menu.addItem(safetySubmenuItem)

        // Preferences Submenu
        prefSubmenu = NSMenu()
        prefSubmenu.autoenablesItems = false

        defaultDurationItem = NSMenuItem(title: "Set Default Duration...", action: #selector(changeDefaultDurationDialog(_:)), keyEquivalent: "")
        defaultDurationItem.target = self
        prefSubmenu.addItem(defaultDurationItem)

        showCountdownItem = NSMenuItem(title: "Show Countdown in Menu Bar", action: #selector(toggleShowCountdown(_:)), keyEquivalent: "")
        showCountdownItem.target = self
        prefSubmenu.addItem(showCountdownItem)

        showInDockItem = NSMenuItem(title: "Show App Icon in Dock", action: #selector(toggleShowInDock(_:)), keyEquivalent: "")
        showInDockItem.target = self
        prefSubmenu.addItem(showInDockItem)

        soundItem = NSMenuItem(title: "Sound Notifications", action: #selector(toggleSoundNotifications(_:)), keyEquivalent: "")
        soundItem.target = self
        prefSubmenu.addItem(soundItem)

        prefSubmenu.addItem(NSMenuItem.separator())

        setupSudoItem = NSMenuItem(title: "Setup Passwordless Sudo...", action: #selector(runSetup(_:)), keyEquivalent: "")
        setupSudoItem.target = self
        prefSubmenu.addItem(setupSudoItem)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        prefSubmenu.addItem(loginItem)

        prefSubmenu.addItem(NSMenuItem.separator())

        // About Ghost Mode item
        aboutItem = NSMenuItem(title: "About Ghost Mode...", action: #selector(showAboutDialog(_:)), keyEquivalent: "")
        aboutItem.target = self
        prefSubmenu.addItem(aboutItem)

        // Report Bug / Suggestion item
        reportBugItem = NSMenuItem(title: "Report Bug / Suggestion...", action: #selector(openReportIssuePage(_:)), keyEquivalent: "")
        reportBugItem.target = self
        prefSubmenu.addItem(reportBugItem)

        // View GitHub item
        viewGitHubItem = NSMenuItem(title: "View Source on GitHub...", action: #selector(openGitHubPage(_:)), keyEquivalent: "")
        viewGitHubItem.target = self
        prefSubmenu.addItem(viewGitHubItem)

        preferencesSubmenuItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferencesSubmenuItem.submenu = prefSubmenu
        menu.addItem(preferencesSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        // Quick Feedback & Bug Report Item in Root Menu
        let quickFeedbackItem = NSMenuItem(title: "Feedback & Bug Reports...", action: #selector(openReportIssuePage(_:)), keyEquivalent: "")
        quickFeedbackItem.target = self
        menu.addItem(quickFeedbackItem)

        // Developer Attribution Footer
        developerCreditItem = NSMenuItem(title: "Developed by \(AppMetadata.author)", action: #selector(showAboutDialog(_:)), keyEquivalent: "")
        developerCreditItem.target = self
        menu.addItem(developerCreditItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Ghost Mode", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Timer Tick & State Monitoring
    func timerTick() {
        let currentLidClosed = DisplayManager.shared.isLidClosed()
        let isSleepDisabledInSystem = PowerManager.shared.checkLidSleepDisabled()
        let battery = PowerManager.shared.getBatteryStatus()

        // 1. Lid Transition Detection (for laptops)
        if DisplayManager.shared.hasLid() {
            if currentLidClosed && !lastLidClosedState {
                print("Ghost Mode: Lid Closed event detected.")
                if Preferences.shared.turnOffScreenOnLidClose && isSleepDisabledInSystem {
                    print("Ghost Mode: Automatically sleeping display for closed lid.")
                    DisplayManager.shared.turnOffDisplay()
                }
            } else if !currentLidClosed && lastLidClosedState {
                print("Ghost Mode: Lid Opened event detected.")
            }
            lastLidClosedState = currentLidClosed
        }

        // 2. Safety Guards (Active ONLY when Sleep Blocking is ON)
        if isSleepDisabledInSystem {
            // Low Battery Cutoff Check (if device has battery)
            if Preferences.shared.batteryCutoffEnabled, let bat = battery {
                if !bat.isAC && bat.percent <= Preferences.shared.batteryCutoffThreshold {
                    print("Ghost Mode: Low battery threshold reached (\(bat.percent)%). Disengaging Ghost Mode.")
                    stopKeepAwakeSession(reason: .lowBattery(percent: bat.percent))
                    return
                }
            }

            // AC Power Only Check (if device has battery/AC status)
            if Preferences.shared.acOnlyModeEnabled, let bat = battery {
                if !bat.isAC && lastACState {
                    print("Ghost Mode: AC adapter disconnected. Reverting to normal sleep.")
                    stopKeepAwakeSession(reason: .unpluggedAC)
                    return
                }
            }

            // Thermal Protection Check
            if Preferences.shared.thermalGuardEnabled {
                let thermal = ProcessInfo.processInfo.thermalState
                if thermal == .serious || thermal == .critical {
                    print("Ghost Mode: High thermal pressure detected. Reverting to normal sleep.")
                    stopKeepAwakeSession(reason: .thermalOverheat)
                    return
                }
            }

            // Timer Expiration Check
            if let endDate = sessionEndDate {
                let remaining = Int(endDate.timeIntervalSinceNow)
                if remaining <= 0 {
                    print("Ghost Mode: Session timer expired.")
                    stopKeepAwakeSession(reason: .timerExpired)
                    return
                }
            }
        } else {
            if isKeepAwakeActive {
                isKeepAwakeActive = false
                sessionEndDate = nil
                isIndefiniteSession = false
                activeInitialDurationSeconds = nil
            }
        }

        if let bat = battery {
            lastACState = bat.isAC
        }

        updateStatusUI()
    }

    // MARK: - UI Updates
    func updateStatusUI() {
        let isSleepDisabled = PowerManager.shared.checkLidSleepDisabled()
        let isLidClosed = DisplayManager.shared.isLidClosed()
        let hasLid = DisplayManager.shared.hasLid()
        let sudoConfigured = PowerManager.shared.isPasswordlessSudoConfigured()
        let battery = PowerManager.shared.getBatteryStatus()

        var remainingSeconds: Int? = nil
        if isSleepDisabled, let endDate = sessionEndDate {
            remainingSeconds = max(0, Int(endDate.timeIntervalSinceNow))
        }

        // 1. Update Clean Upper Dashboard
        updateDashboard(isSleepDisabled: isSleepDisabled, remainingSeconds: remainingSeconds, battery: battery, isLidClosed: isLidClosed, hasLid: hasLid)

        // 2. Extend submenu only makes sense while a session is running
        extendSubmenuItem.isHidden = !isSleepDisabled

        // 3. Presets Submenu Checkmarks & (Default) Tags
        let defSecs = Preferences.shared.defaultDuration
        var matchedPreset = false

        for entry in presetMenuItems {
            let isDefault = (entry.seconds == defSecs)
            let suffix = isDefault ? " (Default)" : ""
            entry.item.title = "\(entry.baseTitle)\(suffix)"

            if isSleepDisabled {
                if entry.seconds == -1 && isIndefiniteSession {
                    entry.item.state = .on
                    matchedPreset = true
                } else if entry.seconds > 0 && activeInitialDurationSeconds == entry.seconds {
                    entry.item.state = .on
                    matchedPreset = true
                } else {
                    entry.item.state = .off
                }
            } else {
                entry.item.state = .off
            }
        }

        // Custom Duration menu item checkmark
        if isSleepDisabled && !matchedPreset && !isIndefiniteSession, let initSecs = activeInitialDurationSeconds {
            customPresetMenuItem.title = "Custom Duration (\(formatDurationHuman(initSecs))) ✓"
            customPresetMenuItem.state = .on
        } else {
            customPresetMenuItem.title = "Custom Duration..."
            customPresetMenuItem.state = .off
        }

        // 4. Screen, Safety & Preferences Items
        screenOnLidCloseItem.state = Preferences.shared.turnOffScreenOnLidClose ? .on : .off
        screenOnLidCloseItem.isHidden = !hasLid

        let cutoffEnabled = Preferences.shared.batteryCutoffEnabled
        let cutoffVal = Preferences.shared.batteryCutoffThreshold
        lowBatteryOffItem.state = (!cutoffEnabled || cutoffVal == 0) ? .on : .off
        lowBattery5Item?.state = (cutoffEnabled && cutoffVal == 5) ? .on : .off
        lowBattery10Item?.state = (cutoffEnabled && cutoffVal == 10) ? .on : .off
        lowBattery15Item?.state = (cutoffEnabled && cutoffVal == 15) ? .on : .off
        lowBattery20Item?.state = (cutoffEnabled && cutoffVal == 20) ? .on : .off
        if cutoffEnabled && ![5, 10, 15, 20].contains(cutoffVal) {
            lowBatteryCustomItem.title = "Custom (\(cutoffVal)%) ✓"
            lowBatteryCustomItem.state = .on
        } else {
            lowBatteryCustomItem.title = "Custom %..."
            lowBatteryCustomItem.state = .off
        }

        acOnlyItem.state = Preferences.shared.acOnlyModeEnabled ? .on : .off
        thermalGuardItem.state = Preferences.shared.thermalGuardEnabled ? .on : .off

        let defHuman = formatDurationHuman(Preferences.shared.defaultDuration)
        defaultDurationItem.title = "Set Default Duration... (Currently: \(defHuman))"
        showCountdownItem.state = Preferences.shared.showCountdownInMenuBar ? .on : .off
        showInDockItem.state = Preferences.shared.showInDock ? .on : .off
        soundItem.state = Preferences.shared.soundNotificationsEnabled ? .on : .off
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off

        if sudoConfigured {
            setupSudoItem.title = "Passwordless Sudo: Configured ✓"
            setupSudoItem.isEnabled = false
        } else {
            setupSudoItem.title = "Setup Passwordless Sudo..."
            setupSudoItem.isEnabled = true
        }

        // 5. Menu Bar Icon & Text Badge
        if let button = statusItem.button {
            var iconName = "laptopcomputer.slash"
            var menuBarTitle = ""

            if isSleepDisabled {
                if hasLid && isLidClosed {
                    iconName = "moon.stars.fill"
                } else {
                    iconName = "cup.and.saucer.fill"
                }

                if Preferences.shared.showCountdownInMenuBar {
                    if let rem = remainingSeconds {
                        menuBarTitle = " \(formatDurationCompact(rem))"
                    } else if isIndefiniteSession {
                        menuBarTitle = " ∞"
                    }
                }
            }

            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Ghost Mode") {
                image.isTemplate = true
                button.image = image
            }
            button.title = menuBarTitle
        }
    }

    func updateDashboard(isSleepDisabled: Bool, remainingSeconds: Int?, battery: (percent: Int, isCharging: Bool, isAC: Bool)?, isLidClosed: Bool, hasLid: Bool) {
        dashboardView.configure(
            isActive: isSleepDisabled,
            isIndefinite: isIndefiniteSession,
            remainingSeconds: remainingSeconds,
            initialDurationSeconds: activeInitialDurationSeconds,
            defaultDuration: Preferences.shared.defaultDuration,
            battery: battery,
            isLidClosed: isLidClosed,
            hasLid: hasLid
        )
    }

    // MARK: - Session Management
    func startKeepAwakeSession(durationSeconds: Int) {
        activeInitialDurationSeconds = durationSeconds
        if durationSeconds > 0 {
            isIndefiniteSession = false
            sessionEndDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
        } else {
            isIndefiniteSession = true
            sessionEndDate = nil
        }
        isKeepAwakeActive = true

        let success = PowerManager.shared.setLidSleep(disabled: true)
        if success {
            updateStatusUI()
            let durationText = durationSeconds > 0 ? formatDurationHuman(durationSeconds) : "Indefinite"
            NotificationHelper.send(
                title: "👻 Ghost Mode Active",
                subtitle: "Session Active (\(durationText))",
                message: "Mac will stay awake. Screen will power down to conserve energy."
            )
        } else {
            isKeepAwakeActive = false
            sessionEndDate = nil
            isIndefiniteSession = false
            activeInitialDurationSeconds = nil
            showErrorAlert(
                title: "Authentication Required",
                message: "Ghost Mode requires passwordless sudo or authorization to manage sleep. Please click 'Setup Passwordless Sudo...' in Preferences."
            )
        }
    }

    func stopKeepAwakeSession(reason: SessionStopReason) {
        isKeepAwakeActive = false
        sessionEndDate = nil
        isIndefiniteSession = false
        activeInitialDurationSeconds = nil

        _ = PowerManager.shared.setLidSleep(disabled: false)
        updateStatusUI()

        switch reason {
        case .userManual:
            NotificationHelper.send(
                title: "Ghost Mode",
                subtitle: "Normal Sleep Restored",
                message: "Mac will now sleep normally when closing the lid or idling."
            )
        case .timerExpired:
            NotificationHelper.send(
                title: "Ghost Mode Timer Finished",
                subtitle: "Session Completed",
                message: "Your session has ended. Normal sleep behavior has been restored."
            )
        case .lowBattery(let pct):
            NotificationHelper.send(
                title: "⚠️ Ghost Mode Battery Shield",
                subtitle: "Low Battery (\(pct)%)",
                message: "Ghost Mode automatically disengaged to protect your battery."
            )
        case .unpluggedAC:
            NotificationHelper.send(
                title: "🔌 Ghost Mode AC Trigger",
                subtitle: "Power Adapter Unplugged",
                message: "Switched to battery power. Reverted to normal sleep mode."
            )
        case .thermalOverheat:
            NotificationHelper.send(
                title: "🌡️ Ghost Mode Thermal Shield",
                subtitle: "High Temperature Detected",
                message: "Ghost Mode disabled to protect hardware from overheating."
            )
        }
    }

    func extendSession(by seconds: Int) {
        if let currentEnd = sessionEndDate {
            sessionEndDate = currentEnd.addingTimeInterval(TimeInterval(seconds))
        } else {
            sessionEndDate = Date().addingTimeInterval(TimeInterval(seconds))
            isIndefiniteSession = false
            isKeepAwakeActive = true
            _ = PowerManager.shared.setLidSleep(disabled: true)
        }
        updateStatusUI()
        NotificationHelper.send(
            title: "Ghost Mode",
            subtitle: "Session Extended",
            message: "Added +\(formatDurationHuman(seconds)) to the timer."
        )
    }

    // MARK: - Menu Actions
    @objc func turnOffScreenClicked(_ sender: NSMenuItem) {
        DisplayManager.shared.turnOffDisplay()
    }

    @objc func extend15MinClicked(_ sender: NSMenuItem) {
        extendSession(by: 15 * 60)
    }

    @objc func extend30MinClicked(_ sender: NSMenuItem) {
        extendSession(by: 30 * 60)
    }

    @objc func extend45MinClicked(_ sender: NSMenuItem) {
        extendSession(by: 45 * 60)
    }

    @objc func extend1HourClicked(_ sender: NSMenuItem) {
        extendSession(by: 3600)
    }

    @objc func extend2HourClicked(_ sender: NSMenuItem) {
        extendSession(by: 7200)
    }

    @objc func extendCustomClicked(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Extend Ghost Mode Session"
        alert.informativeText = "Enter duration to add to the active session (e.g. '15m', '45m', '1.5h', or raw minutes):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Extend Session")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "e.g. 30m or 1h"
        input.stringValue = "30m"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue
            if let secs = parseDurationString(text), secs > 0 {
                extendSession(by: secs)
            } else {
                showErrorAlert(title: "Invalid Duration", message: "Could not parse duration: '\(text)'. Please use formats like '30m', '1h', or '45'.")
            }
        }
    }

    @objc func startPresetSessionClicked(_ sender: NSMenuItem) {
        if let secs = sender.representedObject as? Int {
            startKeepAwakeSession(durationSeconds: secs)
        }
    }

    @objc func startCustomDurationClicked(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Start Custom Ghost Mode Session"
        alert.informativeText = "Enter duration (e.g., '90m' for 90 minutes, '2.5h' for 2.5 hours, or raw minutes):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Session")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "e.g. 90m or 2h"
        input.stringValue = "90m"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue
            if let secs = parseDurationString(text), secs > 0 {
                startKeepAwakeSession(durationSeconds: secs)
            } else {
                showErrorAlert(title: "Invalid Duration", message: "Could not parse duration: '\(text)'. Please use formats like '90m', '2h', or '45'.")
            }
        }
    }

    // MARK: - Preferences & Safety Actions
    @objc func toggleScreenOnLidClose(_ sender: NSMenuItem) {
        Preferences.shared.turnOffScreenOnLidClose.toggle()
        updateStatusUI()
    }

    @objc func setBatteryCutoff(_ sender: NSMenuItem) {
        guard let threshold = sender.representedObject as? Int else { return }
        if threshold == 0 {
            Preferences.shared.batteryCutoffEnabled = false
            Preferences.shared.batteryCutoffThreshold = 0
        } else {
            Preferences.shared.batteryCutoffEnabled = true
            Preferences.shared.batteryCutoffThreshold = threshold
        }
        updateStatusUI()
    }

    @objc func setCustomBatteryCutoffClicked(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Set Custom Battery Safety Threshold"
        alert.informativeText = "Enter the battery percentage (1-50%) below which Ghost Mode will automatically disengage:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        input.placeholderString = "e.g. 10"
        input.stringValue = "\(Preferences.shared.batteryCutoffThreshold)"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let pct = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), pct >= 1 && pct <= 50 {
                Preferences.shared.batteryCutoffThreshold = pct
                Preferences.shared.batteryCutoffEnabled = true
                updateStatusUI()
            } else {
                showErrorAlert(title: "Invalid Percentage", message: "Please enter a number between 1 and 50.")
            }
        }
    }

    @objc func toggleACOnlyMode(_ sender: NSMenuItem) {
        Preferences.shared.acOnlyModeEnabled.toggle()
        updateStatusUI()
    }

    @objc func toggleThermalGuard(_ sender: NSMenuItem) {
        Preferences.shared.thermalGuardEnabled.toggle()
        updateStatusUI()
    }

    @objc func toggleShowCountdown(_ sender: NSMenuItem) {
        Preferences.shared.showCountdownInMenuBar.toggle()
        updateStatusUI()
    }

    @objc func toggleShowInDock(_ sender: NSMenuItem) {
        Preferences.shared.showInDock.toggle()
        let inDock = Preferences.shared.showInDock
        NSApp.setActivationPolicy(inDock ? .regular : .accessory)
        updateStatusUI()
    }

    @objc func toggleSoundNotifications(_ sender: NSMenuItem) {
        Preferences.shared.soundNotificationsEnabled.toggle()
        updateStatusUI()
    }

    @objc func changeDefaultDurationDialog(_ sender: NSMenuItem) {
        let currentHuman = formatDurationHuman(Preferences.shared.defaultDuration)
        let alert = NSAlert()
        alert.messageText = "Configure Default Duration"
        alert.informativeText = "Currently set to: \(currentHuman).\n\nEnter new default duration for 1-click 'Turn On Ghost Mode' (e.g. '1h', '30m', '2h', '45m'):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Default")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "e.g. 1h or 30m"
        input.stringValue = currentHuman
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue
            if let secs = parseDurationString(text), secs > 0 {
                Preferences.shared.defaultDuration = secs
                updateStatusUI()
                NotificationHelper.send(
                    title: "Ghost Mode",
                    subtitle: "Default Duration Saved",
                    message: "1-click Ghost Mode now defaults to \(formatDurationHuman(secs))."
                )
            } else {
                showErrorAlert(title: "Invalid Duration", message: "Could not parse duration '\(text)'. Please use formats like '1h', '90m', or '45'.")
            }
        }
    }

    @objc func runSetup(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Setup Passwordless Sudo for Ghost Mode"
        alert.informativeText = "Ghost Mode will configure passwordless access for the pmset utility in /private/etc/sudoers.d/ghostmode.\n\nDeveloped by \(AppMetadata.author).\n\nProceed to authenticate with administrator password?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let bundlePath = Bundle.main.bundlePath
            let scriptPath = "\(bundlePath)/Contents/Resources/ghostmode_setup.sh"

            let success = PowerManager.shared.runSudoCommandWithAppleScript(command: "\"\(scriptPath)\"")
            if success && PowerManager.shared.isPasswordlessSudoConfigured() {
                let successAlert = NSAlert()
                successAlert.messageText = "Setup Successful"
                successAlert.informativeText = "Passwordless access configured successfully! You can now toggle Ghost Mode instantly."
                successAlert.alertStyle = .informational
                successAlert.addButton(withTitle: "Awesome")
                successAlert.runModal()
                updateStatusUI()
            } else {
                showErrorAlert(title: "Setup Failed", message: "Failed to configure passwordless access. Please verify credentials or directory permissions.")
            }
        }
    }

    @objc func showAboutDialog(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "\(AppMetadata.name) v\(AppMetadata.version)"
        alert.informativeText = """
        Developed by \(AppMetadata.author)
        \(AppMetadata.copyright)

        \(AppMetadata.summary)

        • Digital ID: \(AppMetadata.digitalSignature)
        • Architecture: Universal Binary (Apple Silicon + Intel 64-bit)
        • Compatibility: macOS 12.0+ (Monterey, Ventura, Sonoma, Sequoia+)
        • Open Source: GitHub Community Edition
        """
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Report Bug / Suggestion")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: AppMetadata.githubRepoURL) {
                NSWorkspace.shared.open(url)
            }
        } else if response == .alertThirdButtonReturn {
            if let url = URL(string: AppMetadata.reportURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func openReportIssuePage(_ sender: NSMenuItem) {
        if let url = URL(string: AppMetadata.reportURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openGitHubPage(_ sender: NSMenuItem) {
        if let url = URL(string: AppMetadata.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        let currentlyEnabled = isLaunchAtLoginEnabled()
        toggleLaunchAtLogin(enabled: !currentlyEnabled)
        updateStatusUI()
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    // MARK: - Launch Agent Management
    func getLaunchAgentPath() -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent("Library/LaunchAgents/com.arpit.ghostmode.plist")
    }

    func isLaunchAtLoginEnabled() -> Bool {
        let plistURL = getLaunchAgentPath()
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    func toggleLaunchAtLogin(enabled: Bool) {
        let plistURL = getLaunchAgentPath()
        if enabled {
            let bundlePath = Bundle.main.bundlePath
            let execPath = "\(bundlePath)/Contents/MacOS/GhostMode"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.arpit.ghostmode</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            let directoryURL = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Strict Single-Instance Entrypoint
if !enforceSingleInstance() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
