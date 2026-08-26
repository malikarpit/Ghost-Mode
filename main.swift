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
    static let version = "2.0"
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
        static let appFreezeOnLidCloseEnabled = "appFreezeOnLidCloseEnabled"
        static let appFreezeWhitelist = "appFreezeWhitelist"
        static let keepAudioActiveOnLidClose = "keepAudioActiveOnLidClose"
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

    var appFreezeOnLidCloseEnabled: Bool {
        get { return defaults.bool(forKey: Keys.appFreezeOnLidCloseEnabled) }
        set { defaults.set(newValue, forKey: Keys.appFreezeOnLidCloseEnabled) }
    }

    var keepAudioActiveOnLidClose: Bool {
        get {
            if defaults.object(forKey: Keys.keepAudioActiveOnLidClose) == nil { return true }
            return defaults.bool(forKey: Keys.keepAudioActiveOnLidClose)
        }
        set { defaults.set(newValue, forKey: Keys.keepAudioActiveOnLidClose) }
    }

    var appFreezeWhitelist: [String] {
        get {
            if let arr = defaults.stringArray(forKey: Keys.appFreezeWhitelist) {
                return arr
            }
            return ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
        }
        set { defaults.set(newValue, forKey: Keys.appFreezeWhitelist) }
    }
}

// MARK: - Process Diagnostics (Mach Kernel, < 1 Microsecond, 0 Subprocesses)
struct ProcessDiagnostics {
    static func getMemoryFootprintMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / (1024.0 * 1024.0)
        }
        return 16.0
    }

    static func getGhostModeCPUPercentage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kerr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kerr == KERN_SUCCESS, let list = threadList else { return 0.0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(threadCount * UInt32(MemoryLayout<thread_t>.size)))
        }

        var totalUsage: Double = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let thErr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if thErr == KERN_SUCCESS {
                if (info.flags & TH_FLAGS_IDLE) == 0 {
                    totalUsage += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
                }
            }
        }
        return totalUsage
    }
}

// MARK: - App Freezer & Battery Isolation Manager (Safe SIGSTOP / SIGCONT in RAM)
class AppFreezer {
    static let shared = AppFreezer()
    private(set) var frozenPids = Set<pid_t>()

    // Permanent Protected Bundle Identifiers & System Daemons (NEVER frozen under any circumstance)
    private let systemProtectedIdentifiers: Set<String> = [
        "com.arpit.GhostMode",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.SystemUIServer",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.bluetoothd",
        "com.apple.airportd",
        "com.apple.coreaudiod",
        "com.google.antigravity-ide"
    ]

    func freezeNonWhitelistedApps() -> Int {
        guard Preferences.shared.appFreezeOnLidCloseEnabled else { return 0 }
        unfreezeAllApps()

        let currentPid = getpid()
        let whitelist = Set(Preferences.shared.appFreezeWhitelist)
        let keepAudio = Preferences.shared.keepAudioActiveOnLidClose
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        var count = 0
        var freezeSafari = false
        var freezeChrome = false
        var freezeSpotify = false

        for app in runningApps {
            let pid = app.processIdentifier
            guard pid > 100 && pid != currentPid else { continue }

            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""

            // Safeguard: Never touch critical system services, bluetooth, wifi, or IDE
            if systemProtectedIdentifiers.contains(bid) || whitelist.contains(bid) || whitelist.contains(name) {
                continue
            }

            // Check if app is a media/browser app
            let isSafari = (bid == "com.apple.Safari" || name.contains("Safari"))
            let isChrome = (bid == "com.google.Chrome" || name.contains("Chrome"))
            let isSpotify = (bid == "com.spotify.client" || name.contains("Spotify"))

            if keepAudio && (isSafari || isChrome || isSpotify) {
                // Audio Keep-Alive Mode:
                // Suspend the main UI window process to stop display rendering & window compositing,
                // while leaving audio decoding daemons (com.apple.WebKit.GPU, etc.) completely active.
                if kill(pid, SIGSTOP) == 0 {
                    frozenPids.insert(pid)
                    count += 1
                    print("AppFreezer: Suspended UI for '\(name)' (PID: \(pid)) in RAM (Audio kept streaming).")
                }
                // Do NOT freeze WebKit.GPU or WebKit.Networking or CoreAudio so music keeps playing!
                continue
            }

            // Standard freeze for regular background desktop apps
            if kill(pid, SIGSTOP) == 0 {
                frozenPids.insert(pid)
                count += 1
                print("AppFreezer: Suspended '\(name)' (PID: \(pid)) in RAM.")

                if isSafari { freezeSafari = true }
                if isChrome { freezeChrome = true }
                if isSpotify { freezeSpotify = true }
            }
        }

        // If audio keep-alive is OFF and browser was frozen, also halt audio decoders
        if !keepAudio {
            if freezeSafari {
                let safariHelpers = getPidsMatching(patterns: ["com.apple.WebKit.WebContent", "com.apple.WebKit.GPU", "com.apple.WebKit.Networking"])
                for hPid in safariHelpers {
                    if hPid > 100 && hPid != currentPid && !frozenPids.contains(hPid) {
                        if kill(hPid, SIGSTOP) == 0 {
                            frozenPids.insert(hPid)
                        }
                    }
                }
            }
            if freezeChrome {
                let chromeHelpers = getPidsMatching(patterns: ["Google Chrome Helper"])
                for hPid in chromeHelpers {
                    if hPid > 100 && hPid != currentPid && !frozenPids.contains(hPid) {
                        if kill(hPid, SIGSTOP) == 0 {
                            frozenPids.insert(hPid)
                        }
                    }
                }
            }
            if freezeSpotify {
                let spotifyHelpers = getPidsMatching(patterns: ["Spotify Helper"])
                for hPid in spotifyHelpers {
                    if hPid > 100 && hPid != currentPid && !frozenPids.contains(hPid) {
                        if kill(hPid, SIGSTOP) == 0 {
                            frozenPids.insert(hPid)
                        }
                    }
                }
            }
        }

        return count
    }

    private func getPidsMatching(patterns: [String]) -> [pid_t] {
        let numPids = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard numPids > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(numPids) / MemoryLayout<pid_t>.size)
        let bytesUsed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, numPids)
        let actualCount = Int(bytesUsed) / MemoryLayout<pid_t>.size

        var matches: [pid_t] = []
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 100 else { continue }
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLength > 0 {
                let path = String(cString: pathBuffer)
                for pattern in patterns {
                    if path.localizedCaseInsensitiveContains(pattern) {
                        matches.append(pid)
                        break
                    }
                }
            }
        }
        return matches
    }

    func unfreezeAllApps() {
        guard !frozenPids.isEmpty else { return }
        for pid in frozenPids {
            kill(pid, SIGCONT)
            print("AppFreezer: Resumed PID \(pid).")
        }
        frozenPids.removeAll()
    }
}

// MARK: - Display & Hardware Manager (MacBook + Desktop Macs)
class DisplayManager {
    static let shared = DisplayManager()

    func hasLid() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        if let prop = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
            _ = prop.takeRetainedValue()
            return true
        }
        return false
    }

    func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        if let propRef = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
            let prop = propRef.takeRetainedValue()
            if let b = prop as? Bool { return b }
            if let num = prop as? NSNumber { return num.boolValue }
            if CFGetTypeID(prop) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((prop as! CFBoolean))
            }
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
    private var powerAssertionID: IOPMAssertionID = 0

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

    private var _cachedSudoConfigured: Bool? = nil

    func isPasswordlessSudoConfigured(forceRefresh: Bool = false) -> Bool {
        if !forceRefresh, let cached = _cachedSudoConfigured {
            return cached
        }
        let (_, exitCode) = shell("sudo -n /usr/bin/pmset -g")
        let result = (exitCode == 0)
        _cachedSudoConfigured = result
        return result
    }

    func invalidateSudoCache() {
        _cachedSudoConfigured = nil
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
                startNativePowerAssertion()
            } else {
                stopNativePowerAssertion()
            }
        }
        return success
    }

    func startNativePowerAssertion() {
        guard powerAssertionID == 0 else { return }
        let reason = "Ghost Mode Keep-Awake Session (by \(AppMetadata.author))" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &powerAssertionID
        )
        if result == kIOReturnSuccess {
            print("PowerManager: Native IOKit power assertion active (ID: \(powerAssertionID)).")
        } else {
            print("PowerManager: Failed to create IOKit power assertion (error: \(result)).")
        }
    }

    func stopNativePowerAssertion() {
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            print("PowerManager: Native IOKit power assertion released (ID: \(powerAssertionID)).")
            powerAssertionID = 0
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
    private static let viewWidth: CGFloat = 270
    private static let viewHeight: CGFloat = 100

    private let iconView = NSImageView(frame: NSRect(x: 14, y: 76, width: 18, height: 18))
    private let titleLabel = NSTextField(labelWithString: "Ghost Mode")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = ProgressBarView(frame: NSRect(x: 14, y: 64, width: 242, height: 5))
    private let detailLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(frame: .zero)
    private let secondaryButton = NSButton(frame: NSRect(x: 140, y: 16, width: 116, height: 24))

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
        titleLabel.frame = NSRect(x: 38, y: 77, width: 100, height: 16)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        statusLabel.frame = NSRect(x: 140, y: 77, width: 116, height: 16)
        statusLabel.alignment = .right
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        detailLabel.frame = NSRect(x: 14, y: 47, width: 75, height: 14)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor

        infoLabel.frame = NSRect(x: 90, y: 47, width: 166, height: 14)
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
            detailLabel.stringValue = "Indefinite"
        } else {
            progressBar.isHidden = true
            detailLabel.stringValue = "Ready"
        }

        // Right-hand battery & live dynamic zero-resource telemetry text
        var info = ""
        let memMB = ProcessDiagnostics.getMemoryFootprintMB()
        let memStr = memMB < 100 ? String(format: "%.0fMB", memMB) : "\(Int(memMB))MB"
        let cpuPct = ProcessDiagnostics.getGhostModeCPUPercentage()
        let cpuStr = String(format: "%.1f%%", cpuPct)
        info += "⚡ \(cpuStr) · \(memStr)"

        if let bat = battery {
            let symbol = bat.isCharging ? "⚡" : (bat.isAC ? "🔌" : "🔋")
            info += "  ·  \(symbol)\(bat.percent)%"
        }
        infoLabel.stringValue = info

        // Quick-action buttons: full-width "Turn On" when idle, "Stop" + "+30m" when active
        if isActive {
            primaryButton.title = "🛑 Stop"
            primaryButton.frame = NSRect(x: 14, y: 16, width: 116, height: 24)
            secondaryButton.isHidden = false
        } else {
            primaryButton.title = "👻 Turn On (\(formatDurationHuman(defaultDuration)))"
            primaryButton.frame = NSRect(x: 14, y: 16, width: 242, height: 24)
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
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!

    // Active & Menu Timers (Strictly nil when idle)
    private var sessionExpirationTimer: Timer?
    private var countdownBadgeTimer: Timer?
    private var menuTrackingTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var iokitNotifyPort: IONotificationPortRef?
    private var iokitNotification: io_object_t = 0
    private var iokitRootDomain: io_service_t = 0
    private var isMenuOpen: Bool = false

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

    var appFreezeItem: NSMenuItem!
    var keepAudioItem: NSMenuItem!
    var appFreezeWhitelistItem: NSMenuItem!
    var appFreezeWhitelistSubmenu = NSMenu()

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
        setupEventMonitoring()

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
        } else {
            isKeepAwakeActive = false
            isIndefiniteSession = false
            sessionEndDate = nil
            activeInitialDurationSeconds = nil
        }

        updateStatusUI()

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
        teardownEventMonitoring()
        stopSessionTimers()
        AppFreezer.shared.unfreezeAllApps()
        PowerManager.shared.stopNativePowerAssertion()
        if PowerManager.shared.isPasswordlessSudoConfigured() {
            _ = PowerManager.shared.shell("sudo /usr/bin/pmset disablesleep 0")
        }
        if globalLockFileDescriptor >= 0 {
            flock(globalLockFileDescriptor, LOCK_UN)
            close(globalLockFileDescriptor)
        }
    }

    // MARK: - Event-Driven Monitoring (Zero Polling, Zero Idle Overhead)
    func setupEventMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 1. IOKit Power Sources Notification RunLoop Source (Battery & AC transitions)
        let psCallback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            delegate.handlePowerSourceChanged()
        }
        if let source = IOPSNotificationCreateRunLoopSource(psCallback, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        // 2. IOKit RootDomain Hardware Clamshell / Lid Notification (Zero Polling)
        iokitNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        if let notifyPort = iokitNotifyPort, let source = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            iokitRootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            if iokitRootDomain != 0 {
                let interestCallback: IOServiceInterestCallback = { refcon, service, messageType, messageArgument in
                    guard let refcon = refcon else { return }
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    delegate.handleIOPMInterest(messageType: messageType)
                }
                _ = IOServiceAddInterestNotification(
                    notifyPort,
                    iokitRootDomain,
                    kIOGeneralInterest,
                    interestCallback,
                    context,
                    &iokitNotification
                )
            }
        }

        // 3. Thermal State Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalStateChanged(_:)),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        // 4. Display / Lid Sleep Notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceScreensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceScreensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func teardownEventMonitoring() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
        if iokitNotification != 0 {
            IOObjectRelease(iokitNotification)
            iokitNotification = 0
        }
        if iokitRootDomain != 0 {
            IOObjectRelease(iokitRootDomain)
            iokitRootDomain = 0
        }
        if let notifyPort = iokitNotifyPort {
            IONotificationPortDestroy(notifyPort)
            iokitNotifyPort = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func handleIOPMInterest(messageType: UInt32) {
        guard DisplayManager.shared.hasLid() else { return }
        let currentLidClosed = DisplayManager.shared.isLidClosed()
        if currentLidClosed != lastLidClosedState {
            print("Ghost Mode: Hardware Clamshell Lid event detected -> isLidClosed: \(currentLidClosed)")
            if currentLidClosed && !lastLidClosedState {
                if isKeepAwakeActive && Preferences.shared.turnOffScreenOnLidClose {
                    print("Ghost Mode: Automatically sleeping display for closed lid.")
                    DisplayManager.shared.turnOffDisplay()
                }
                if isKeepAwakeActive && Preferences.shared.appFreezeOnLidCloseEnabled {
                    let count = AppFreezer.shared.freezeNonWhitelistedApps()
                    if count > 0 {
                        print("Ghost Mode: Suspended \(count) background apps in RAM for maximum battery savings.")
                    }
                }
            } else if !currentLidClosed && lastLidClosedState {
                // Lid opened -> Instantly resume all suspended apps
                AppFreezer.shared.unfreezeAllApps()
            }
            lastLidClosedState = currentLidClosed
            updateStatusUI()
        }
    }



    func handlePowerSourceChanged() {
        let battery = PowerManager.shared.getBatteryStatus()
        guard let bat = battery else { return }

        if isKeepAwakeActive {
            // Low Battery Cutoff Check
            if Preferences.shared.batteryCutoffEnabled {
                if !bat.isAC && bat.percent <= Preferences.shared.batteryCutoffThreshold {
                    print("Ghost Mode: Low battery threshold reached (\(bat.percent)%). Disengaging Ghost Mode.")
                    stopKeepAwakeSession(reason: .lowBattery(percent: bat.percent))
                    return
                }
            }

            // AC Power Only Check
            if Preferences.shared.acOnlyModeEnabled {
                if !bat.isAC && lastACState {
                    print("Ghost Mode: AC adapter disconnected. Reverting to normal sleep.")
                    stopKeepAwakeSession(reason: .unpluggedAC)
                    return
                }
            }
        }
        lastACState = bat.isAC

        if isMenuOpen {
            updateStatusUI()
        }
    }

    @objc func handleThermalStateChanged(_ notification: Notification) {
        if isKeepAwakeActive && Preferences.shared.thermalGuardEnabled {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical {
                print("Ghost Mode: High thermal pressure detected (\(thermal)). Reverting to normal sleep.")
                stopKeepAwakeSession(reason: .thermalOverheat)
            }
        }
    }

    @objc func handleWorkspaceScreensDidSleep(_ notification: Notification) {
        if isKeepAwakeActive && DisplayManager.shared.hasLid() {
            let lidClosed = DisplayManager.shared.isLidClosed()
            if lidClosed && !lastLidClosedState {
                print("Ghost Mode: Lid closed detected.")
                if Preferences.shared.turnOffScreenOnLidClose {
                    DisplayManager.shared.turnOffDisplay()
                }
            }
            lastLidClosedState = lidClosed
        }
    }

    @objc func handleWorkspaceScreensDidWake(_ notification: Notification) {
        AppFreezer.shared.unfreezeAllApps()
        if DisplayManager.shared.hasLid() {
            lastLidClosedState = DisplayManager.shared.isLidClosed()
        }
    }

    // MARK: - Menu Setup
    func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

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

        // Safety Submenu
        safetySubmenu = NSMenu()
        safetySubmenu.autoenablesItems = false

        screenOnLidCloseItem = NSMenuItem(title: "Turn Off Screen on Lid Close", action: #selector(toggleScreenOnLidClose(_:)), keyEquivalent: "")
        screenOnLidCloseItem.target = self
        safetySubmenu.addItem(screenOnLidCloseItem)

        safetySubmenu.addItem(NSMenuItem.separator())

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

        safetySubmenu.addItem(NSMenuItem.separator())

        // App Freeze & Battery Isolation on Lid Close
        appFreezeItem = NSMenuItem(title: "Freeze Other Apps on Lid Close 🔋", action: #selector(toggleAppFreeze(_:)), keyEquivalent: "")
        appFreezeItem.target = self
        safetySubmenu.addItem(appFreezeItem)

        keepAudioItem = NSMenuItem(title: "Keep Music & Audio Streaming (Safari/Chrome) 🎵", action: #selector(toggleKeepAudio(_:)), keyEquivalent: "")
        keepAudioItem.target = self
        safetySubmenu.addItem(keepAudioItem)

        appFreezeWhitelistSubmenu = NSMenu()
        appFreezeWhitelistSubmenu.autoenablesItems = false
        appFreezeWhitelistItem = NSMenuItem(title: "Keep Specific Apps Running...", action: nil, keyEquivalent: "")
        appFreezeWhitelistItem.submenu = appFreezeWhitelistSubmenu
        safetySubmenu.addItem(appFreezeWhitelistItem)

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

    // MARK: - NSMenuDelegate (Just-In-Time UI Rendering & Dropdown Live Progress)
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        lastLidClosedState = DisplayManager.shared.isLidClosed()
        refreshAppFreezeWhitelistSubmenu()
        updateStatusUI()

        // If an active timed session is in progress, update progress smoothly while the dropdown is open
        if isKeepAwakeActive && !isIndefiniteSession && sessionEndDate != nil {
            menuTrackingTimer?.invalidate()
            let trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.menuTrackingTick()
            }
            RunLoop.current.add(trackTimer, forMode: .common)
            menuTrackingTimer = trackTimer
        }
    }

    func refreshAppFreezeWhitelistSubmenu() {
        appFreezeWhitelistSubmenu.removeAllItems()
        let currentPid = getpid()
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != currentPid && $0.bundleIdentifier != "com.apple.finder" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        let whitelist = Set(Preferences.shared.appFreezeWhitelist)

        if runningApps.isEmpty {
            let emptyItem = NSMenuItem(title: "No other user apps open", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            appFreezeWhitelistSubmenu.addItem(emptyItem)
            return
        }

        let descItem = NSMenuItem(title: "Checked apps stay active in Ghost Mode:", action: nil, keyEquivalent: "")
        descItem.isEnabled = false
        appFreezeWhitelistSubmenu.addItem(descItem)
        appFreezeWhitelistSubmenu.addItem(NSMenuItem.separator())

        for app in runningApps {
            guard let name = app.localizedName, !name.isEmpty else { continue }
            let identifier = app.bundleIdentifier ?? name
            let isWhitelisted = whitelist.contains(identifier) || whitelist.contains(name)

            let item = NSMenuItem(title: name, action: #selector(toggleAppInWhitelist(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            item.state = isWhitelisted ? .on : .off
            if let icon = app.icon {
                let smallIcon = icon.copy() as! NSImage
                smallIcon.size = NSSize(width: 16, height: 16)
                item.image = smallIcon
            }
            appFreezeWhitelistSubmenu.addItem(item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        menuTrackingTimer?.invalidate()
        menuTrackingTimer = nil
    }

    private func menuTrackingTick() {
        guard isMenuOpen, isKeepAwakeActive else {
            menuTrackingTimer?.invalidate()
            menuTrackingTimer = nil
            return
        }
        var remainingSeconds: Int? = nil
        if let endDate = sessionEndDate {
            let rem = max(0, Int(endDate.timeIntervalSinceNow))
            remainingSeconds = rem
            if rem <= 0 {
                stopKeepAwakeSession(reason: .timerExpired)
                return
            }
        }
        let battery = PowerManager.shared.getBatteryStatus()
        let isLidClosed = DisplayManager.shared.isLidClosed()
        let hasLid = DisplayManager.shared.hasLid()
        lastLidClosedState = isLidClosed
        updateDashboard(isSleepDisabled: true, remainingSeconds: remainingSeconds, battery: battery, isLidClosed: isLidClosed, hasLid: hasLid)
    }

    // MARK: - Active Session Timer Management (0.0% CPU When Idle & Adaptive When Active)
    private func startSessionTimers(durationSeconds: Int) {
        stopSessionTimers()

        if durationSeconds > 0 {
            let endDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
            sessionEndDate = endDate

            // 1. Precise single-shot expiration timer
            let expTimer = Timer(fireAt: endDate, interval: 0, target: self, selector: #selector(sessionTimerExpired), userInfo: nil, repeats: false)
            RunLoop.current.add(expTimer, forMode: .common)
            sessionExpirationTimer = expTimer

            // 2. Adaptive Countdown Badge Timer (only if user enabled countdown badge)
            if Preferences.shared.showCountdownInMenuBar {
                scheduleNextAdaptiveBadgeTick()
            }
        }
    }

    private func scheduleNextAdaptiveBadgeTick() {
        countdownBadgeTimer?.invalidate()
        guard isKeepAwakeActive, let endDate = sessionEndDate, Preferences.shared.showCountdownInMenuBar else {
            countdownBadgeTimer = nil
            return
        }
        let rem = max(0, Int(endDate.timeIntervalSinceNow))
        guard rem > 0 else { return }

        // Adaptive Scheduling: If > 60s, schedule to fire at the minute boundary.
        // If <= 60s, tick second-by-second for final countdown.
        let interval: TimeInterval
        if rem > 60 {
            let secInCurrentMin = rem % 60
            interval = TimeInterval(secInCurrentMin == 0 ? 60 : secInCurrentMin)
        } else {
            interval = 1.0
        }

        let timer = Timer.scheduledTimer(withTimeInterval: max(0.5, interval), repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.updateMenuBarBadgeOnly()
            self.scheduleNextAdaptiveBadgeTick()
        }
        RunLoop.current.add(timer, forMode: .common)
        countdownBadgeTimer = timer
    }

    private func stopSessionTimers() {
        sessionExpirationTimer?.invalidate()
        sessionExpirationTimer = nil
        countdownBadgeTimer?.invalidate()
        countdownBadgeTimer = nil
        menuTrackingTimer?.invalidate()
        menuTrackingTimer = nil
    }

    @objc private func sessionTimerExpired() {
        print("Ghost Mode: Session timer expired.")
        stopKeepAwakeSession(reason: .timerExpired)
    }

    private func updateMenuBarBadgeOnly() {
        guard let button = statusItem.button else { return }
        guard isKeepAwakeActive, let endDate = sessionEndDate else {
            if !button.title.isEmpty {
                button.title = ""
            }
            countdownBadgeTimer?.invalidate()
            countdownBadgeTimer = nil
            return
        }

        if Preferences.shared.showCountdownInMenuBar {
            let rem = max(0, Int(endDate.timeIntervalSinceNow))
            let newBadge = " \(formatDurationCompact(rem))"
            if button.title != newBadge {
                button.title = newBadge
            }
        } else {
            if !button.title.isEmpty {
                button.title = ""
            }
        }
    }

    // MARK: - UI Updates (In-Memory & Pure Data Formatting)
    func updateStatusUI() {
        let isSleepDisabled = isKeepAwakeActive
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

        // 3. Presets Submenu Title, Checkmarks & (Default) Tags
        presetsSubmenuItem.title = isSleepDisabled ? "Switch Session to..." : "Start Session for..."
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

        appFreezeItem.state = Preferences.shared.appFreezeOnLidCloseEnabled ? .on : .off
        appFreezeItem.isHidden = !hasLid
        keepAudioItem.state = Preferences.shared.keepAudioActiveOnLidClose ? .on : .off
        keepAudioItem.isHidden = !hasLid
        appFreezeWhitelistItem.isHidden = !hasLid

        let defHuman = formatDurationHuman(Preferences.shared.defaultDuration)
        defaultDurationItem.title = "Set Default Duration... (Currently: \(defHuman))"
        showCountdownItem.state = Preferences.shared.showCountdownInMenuBar ? .on : .off
        showInDockItem.state = Preferences.shared.showInDock ? .on : .off
        soundItem.state = Preferences.shared.soundNotificationsEnabled ? .on : .off
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off

        if sudoConfigured {
            setupSudoItem.title = "Revoke Passwordless Sudo..."
            setupSudoItem.state = .on
        } else {
            setupSudoItem.title = "Setup Passwordless Sudo..."
            setupSudoItem.state = .off
        }
        setupSudoItem.isEnabled = true

        // 5. Menu Bar Icon & Text Badge (Deduplicated Property Assignments)
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
            if button.title != menuBarTitle {
                button.title = menuBarTitle
            }
        }
    }

    func updateDashboard(isSleepDisabled: Bool, remainingSeconds: Int?, battery: (percent: Int, isCharging: Bool, isAC: Bool)?, isLidClosed: Bool, hasLid: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        CATransaction.commit()
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
            startSessionTimers(durationSeconds: durationSeconds)
            updateStatusUI()
            
            // Automatically power off screen if lid is already closed when activating Ghost Mode
            if Preferences.shared.turnOffScreenOnLidClose && DisplayManager.shared.hasLid() && DisplayManager.shared.isLidClosed() {
                DisplayManager.shared.turnOffDisplay()
            }
            if Preferences.shared.appFreezeOnLidCloseEnabled && DisplayManager.shared.hasLid() && DisplayManager.shared.isLidClosed() {
                _ = AppFreezer.shared.freezeNonWhitelistedApps()
            }

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
            stopSessionTimers()
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
        stopSessionTimers()
        AppFreezer.shared.unfreezeAllApps()

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
            let newEnd = currentEnd.addingTimeInterval(TimeInterval(seconds))
            sessionEndDate = newEnd
            let remaining = max(0, Int(newEnd.timeIntervalSinceNow))
            startSessionTimers(durationSeconds: remaining)
        } else {
            isIndefiniteSession = false
            isKeepAwakeActive = true
            sessionEndDate = Date().addingTimeInterval(TimeInterval(seconds))
            startSessionTimers(durationSeconds: seconds)
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
        let isSleepDisabled = PowerManager.shared.checkLidSleepDisabled()
        let alert = NSAlert()
        alert.messageText = isSleepDisabled ? "Switch Ghost Mode Session Duration" : "Start Custom Ghost Mode Session"
        alert.informativeText = "Enter duration (e.g., '90m' for 90 minutes, '2.5h' for 2.5 hours, or raw minutes):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: isSleepDisabled ? "Switch Duration" : "Start Session")
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

    @objc func toggleAppFreeze(_ sender: NSMenuItem) {
        Preferences.shared.appFreezeOnLidCloseEnabled.toggle()
        if !Preferences.shared.appFreezeOnLidCloseEnabled {
            AppFreezer.shared.unfreezeAllApps()
        } else if isKeepAwakeActive && DisplayManager.shared.hasLid() && DisplayManager.shared.isLidClosed() {
            _ = AppFreezer.shared.freezeNonWhitelistedApps()
        }
        updateStatusUI()
    }

    @objc func toggleKeepAudio(_ sender: NSMenuItem) {
        Preferences.shared.keepAudioActiveOnLidClose.toggle()
        if isKeepAwakeActive && DisplayManager.shared.hasLid() && DisplayManager.shared.isLidClosed() && Preferences.shared.appFreezeOnLidCloseEnabled {
            _ = AppFreezer.shared.freezeNonWhitelistedApps()
        }
        updateStatusUI()
    }

    @objc func toggleAppInWhitelist(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var list = Preferences.shared.appFreezeWhitelist
        if let idx = list.firstIndex(of: id) {
            list.remove(at: idx)
        } else {
            list.append(id)
        }
        Preferences.shared.appFreezeWhitelist = list
        refreshAppFreezeWhitelistSubmenu()
        updateStatusUI()
    }

    @objc func toggleShowCountdown(_ sender: NSMenuItem) {
        Preferences.shared.showCountdownInMenuBar.toggle()
        if isKeepAwakeActive && !isIndefiniteSession {
            if Preferences.shared.showCountdownInMenuBar {
                scheduleNextAdaptiveBadgeTick()
            } else {
                countdownBadgeTimer?.invalidate()
                countdownBadgeTimer = nil
            }
        }
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
        let isConfigured = PowerManager.shared.isPasswordlessSudoConfigured()

        if isConfigured {
            let alert = NSAlert()
            alert.messageText = "Revoke Passwordless Sudo?"
            alert.informativeText = "Ghost Mode will remove the sudoers authorization rule from /private/etc/sudoers.d/ghostmode.\n\nAfter revoking, macOS will prompt for your administrator password whenever Ghost Mode modifies sleep settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Revoke Authorization")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                let success = PowerManager.shared.runSudoCommandWithAppleScript(command: "/bin/rm -f /private/etc/sudoers.d/ghostmode")
                PowerManager.shared.invalidateSudoCache()
                if success && !PowerManager.shared.isPasswordlessSudoConfigured(forceRefresh: true) {
                    let doneAlert = NSAlert()
                    doneAlert.messageText = "Authorization Revoked"
                    doneAlert.informativeText = "Passwordless sudo has been removed. You will now be prompted for password authentication when sleep settings change."
                    doneAlert.alertStyle = .informational
                    doneAlert.addButton(withTitle: "OK")
                    doneAlert.runModal()
                    updateStatusUI()
                } else {
                    showErrorAlert(title: "Revocation Failed", message: "Failed to remove /private/etc/sudoers.d/ghostmode. You can remove it manually via: sudo rm -f /private/etc/sudoers.d/ghostmode")
                }
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Setup Passwordless Sudo for Ghost Mode"
            alert.informativeText = "Ghost Mode will configure passwordless access for the pmset utility in /private/etc/sudoers.d/ghostmode.\n\nDeveloped by \(AppMetadata.author).\n\nProceed to authenticate with administrator password?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Proceed")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let bundlePath = Bundle.main.bundlePath
                let scriptPath = "\(bundlePath)/Contents/Resources/ghostmode_setup.sh"

                let success = PowerManager.shared.runSudoCommandWithAppleScript(command: "\"\(scriptPath)\"")
                PowerManager.shared.invalidateSudoCache()
                if success && PowerManager.shared.isPasswordlessSudoConfigured(forceRefresh: true) {
                    let successAlert = NSAlert()
                    successAlert.messageText = "Setup Successful"
                    successAlert.informativeText = "Passwordless access configured successfully! You can now toggle Ghost Mode instantly without password prompts."
                    successAlert.alertStyle = .informational
                    successAlert.addButton(withTitle: "Awesome")
                    successAlert.runModal()
                    updateStatusUI()
                } else {
                    showErrorAlert(title: "Setup Failed", message: "Failed to configure passwordless access. Please verify credentials or directory permissions.")
                }
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
