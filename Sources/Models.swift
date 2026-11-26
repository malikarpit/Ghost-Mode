//
//  Models.swift
//  Ghost Mode
//

import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - App Metadata & Signature

public struct AppMetadata {
    public static let name = "Ghost Mode"
    public static let version = "2.2.2"
    public static let author = "Arpit"
    public static let copyright = "Copyright © 2026 Arpit. All rights reserved."
    public static let digitalSignature = "Signed by Arpit (com.arpit.GhostMode)"
    public static let summary = "Keep your Mac running with the lid closed, instantly power down the display to eliminate heat and conserve battery, and set customizable keep-awake timers."
    public static let githubRepoURL = "https://github.com/malikarpit/Ghost-Mode"
    public static let issuesURL = "https://github.com/malikarpit/Ghost-Mode/issues"
    public static let reportURL = "https://github.com/malikarpit/Ghost-Mode/issues/new/choose"
    public static let bundleIdentifier = "com.arpit.GhostMode"
}

// MARK: - Session & Power State Models

public enum SessionStopReason: Equatable, Hashable {
    case userManual
    case timerExpired
    case lowBattery(percent: Int)
    case unpluggedAC
    case thermalOverheat
}

public enum SessionMode: Equatable {
    case idle
    case activeFinite(endDate: Date, totalDuration: Int)
    case activeIndefinite
    case pendingSleepRestore(SessionStopReason)

    public var isActive: Bool {
        switch self {
        case .activeFinite, .activeIndefinite:
            return true
        case .idle, .pendingSleepRestore:
            return false
        }
    }

    public var isIndefinite: Bool {
        if case .activeIndefinite = self { return true }
        return false
    }

    public var endDate: Date? {
        if case .activeFinite(let endDate, _) = self { return endDate }
        return nil
    }

    public var totalDuration: Int? {
        if case .activeFinite(_, let totalDuration) = self { return totalDuration }
        return nil
    }
}

public struct BatteryStatus: Equatable {
    public let percent: Int
    public let isCharging: Bool
    public let isAC: Bool
    public let timeRemainingMinutes: Int?

    public init(percent: Int, isCharging: Bool, isAC: Bool, timeRemainingMinutes: Int? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isAC = isAC
        self.timeRemainingMinutes = timeRemainingMinutes
    }
}

public enum AudioFilterMode: String, Codable, Equatable, CaseIterable {
    case allowAllExceptBlocked
    case allowOnlySelected
}

public struct FrozenProcessRecord: Codable, Hashable {
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64

    public init(pid: pid_t, startSec: UInt64, startUsec: UInt64) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }
}

public struct AppEntry: Identifiable, Equatable {
    public let id: String
    public let pid: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let icon: NSImage?
    public let isPlayingAudio: Bool
    public let isFrozen: Bool
    public let isRunning: Bool
    public let isAudioCatalogPreset: Bool

    public init(
        id: String,
        pid: pid_t,
        name: String,
        bundleIdentifier: String?,
        icon: NSImage? = nil,
        isPlayingAudio: Bool = false,
        isFrozen: Bool = false,
        isRunning: Bool = true,
        isAudioCatalogPreset: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.isPlayingAudio = isPlayingAudio
        self.isFrozen = isFrozen
        self.isRunning = isRunning
        self.isAudioCatalogPreset = isAudioCatalogPreset
    }

    public static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id &&
            lhs.pid == rhs.pid &&
            lhs.name == rhs.name &&
            lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.isPlayingAudio == rhs.isPlayingAudio &&
            lhs.isFrozen == rhs.isFrozen &&
            lhs.isRunning == rhs.isRunning &&
            lhs.isAudioCatalogPreset == rhs.isAudioCatalogPreset
    }
}

public enum AudioRuleDisplayState: Equatable {
    case whitelistedAlwaysOn
    case allowed
    case excludedOrBlocked
}

public struct AudioPresetAppEntry: Equatable {
    public let bundleIdentifier: String
    public let displayName: String
    public let icon: NSImage?

    public init(bundleIdentifier: String, displayName: String, icon: NSImage? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.icon = icon
    }

    public static func == (lhs: AudioPresetAppEntry, rhs: AudioPresetAppEntry) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.displayName == rhs.displayName
    }
}

public enum AudioAppCatalog {
    public static let recentlyPlayedRetentionSeconds: TimeInterval = 600

    public static let presetDedicatedAudioBundleIDs: [String] = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "com.tidal.desktop",
        "com.amazon.music",
        "com.coppertino.Vox",
        "com.brushedtype.doppler-macos",
        "com.swinsian.Swinsian",
        "fm.overcast.Overcast",
        "com.deezer.deezer-desktop",
        "com.qobuz.desktop"
    ]

    private static let presetDedicatedAudioBundleIDSet = Set(presetDedicatedAudioBundleIDs)

    public static func isPresetDedicatedAudioApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return presetDedicatedAudioBundleIDSet.contains(bundleIdentifier)
    }

    public static func discoverInstalledPresetAudioApps(
        resolveApp: ((String) -> (displayName: String, icon: NSImage?)?)? = nil
    ) -> [AudioPresetAppEntry] {
        let resolver: (String) -> (displayName: String, icon: NSImage?)? = resolveApp ?? { bundleID in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            let bundle = Bundle(url: appURL)
            let rawDisplayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawBundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName: String
            if let rawDisplayName, !rawDisplayName.isEmpty {
                displayName = rawDisplayName
            } else if let rawBundleName, !rawBundleName.isEmpty {
                displayName = rawBundleName
            } else {
                displayName = appURL.deletingPathExtension().lastPathComponent
            }
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            return (displayName: displayName, icon: icon)
        }

        var entries: [AudioPresetAppEntry] = []
        for bundleID in presetDedicatedAudioBundleIDs {
            if let resolved = resolver(bundleID) {
                entries.append(
                    AudioPresetAppEntry(
                        bundleIdentifier: bundleID,
                        displayName: resolved.displayName,
                        icon: resolved.icon
                    )
                )
            }
        }

        return entries.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.bundleIdentifier < rhs.bundleIdentifier
        }
    }

    public static func effectiveAudioRuleState(
        bundleID: String?,
        appName: String,
        whitelist: Set<String>,
        mode: AudioFilterMode,
        blockedApps: [String],
        allowedApps: [String]
    ) -> AudioRuleDisplayState {
        var identifiers: [String] = []
        if let bundleID, !bundleID.isEmpty {
            identifiers.append(bundleID)
        }
        if !appName.isEmpty {
            identifiers.append(appName)
        }

        if identifiers.contains(where: { whitelist.contains($0) }) {
            return .whitelistedAlwaysOn
        }

        let isAllowed: Bool
        switch mode {
        case .allowAllExceptBlocked:
            let blocked = Set(blockedApps)
            isAllowed = !identifiers.contains(where: { blocked.contains($0) })
        case .allowOnlySelected:
            let allowed = Set(allowedApps)
            isAllowed = !allowed.isEmpty && identifiers.contains(where: { allowed.contains($0) })
        }
        return isAllowed ? .allowed : .excludedOrBlocked
    }

    public static func buildAudioRuleEntries(
        runningApps: [AppEntry],
        installedPresets: [AudioPresetAppEntry],
        recentlyActiveAudioIDs: Set<String>,
        mode: AudioFilterMode,
        blockedApps: [String],
        allowedApps: [String]
    ) -> [AppEntry] {
        _ = mode
        let explicitRuleIDs = Set(blockedApps).union(allowedApps)
        var entries: [AppEntry] = []
        var runningBundleIDs = Set<String>()

        for app in runningApps {
            if let bid = app.bundleIdentifier, !bid.isEmpty {
                runningBundleIDs.insert(bid)
            }

            var identifiers: [String] = []
            if let bid = app.bundleIdentifier, !bid.isEmpty {
                identifiers.append(bid)
            }
            if !app.name.isEmpty {
                identifiers.append(app.name)
            }

            let isIncluded = app.isPlayingAudio ||
                isPresetDedicatedAudioApp(bundleIdentifier: app.bundleIdentifier) ||
                identifiers.contains(where: { recentlyActiveAudioIDs.contains($0) }) ||
                identifiers.contains(where: { explicitRuleIDs.contains($0) })

            if isIncluded {
                entries.append(app)
            }
        }

        var seenPresetBundleIDs = Set<String>()
        for preset in installedPresets {
            guard !runningBundleIDs.contains(preset.bundleIdentifier),
                  !seenPresetBundleIDs.contains(preset.bundleIdentifier) else {
                continue
            }
            seenPresetBundleIDs.insert(preset.bundleIdentifier)
            entries.append(
                AppEntry(
                    id: "preset-\(preset.bundleIdentifier)",
                    pid: 0,
                    name: preset.displayName,
                    bundleIdentifier: preset.bundleIdentifier,
                    icon: preset.icon,
                    isPlayingAudio: false,
                    isFrozen: false,
                    isRunning: false,
                    isAudioCatalogPreset: true
                )
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.isPlayingAudio != rhs.isPlayingAudio {
                return lhs.isPlayingAudio && !rhs.isPlayingAudio
            }
            if lhs.isRunning != rhs.isRunning {
                return lhs.isRunning && !rhs.isRunning
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

public struct SavedRuleEntry: Identifiable, Equatable {
    public let id: String
    public let identifier: String
    public let displayName: String
    public let icon: NSImage?

    public init(identifier: String, displayName: String, icon: NSImage? = nil) {
        self.id = identifier
        self.identifier = identifier
        self.displayName = displayName
        self.icon = icon
    }

    public static func == (lhs: SavedRuleEntry, rhs: SavedRuleEntry) -> Bool {
        lhs.id == rhs.id &&
            lhs.identifier == rhs.identifier &&
            lhs.displayName == rhs.displayName
    }
}

public struct SystemSnapshot: Equatable {
    public let hasLid: Bool
    public let isLidClosed: Bool
    public let battery: BatteryStatus?
    public let thermalState: ProcessInfo.ThermalState
    public let kernelSleepDisabled: Bool
    public let sudoConfigured: Bool
    public let frozenAppCount: Int

    public init(
        hasLid: Bool,
        isLidClosed: Bool,
        battery: BatteryStatus?,
        thermalState: ProcessInfo.ThermalState,
        kernelSleepDisabled: Bool,
        sudoConfigured: Bool,
        frozenAppCount: Int = 0
    ) {
        self.hasLid = hasLid
        self.isLidClosed = isLidClosed
        self.battery = battery
        self.thermalState = thermalState
        self.kernelSleepDisabled = kernelSleepDisabled
        self.sudoConfigured = sudoConfigured
        self.frozenAppCount = frozenAppCount
    }
}

// MARK: - Interface & Policy Types

public enum SafetyViolation: Equatable {
    case none
    case violation(SessionStopReason)

    public var reason: SessionStopReason? {
        switch self {
        case .none:
            return nil
        case .violation(let reason):
            return reason
        }
    }
}

public enum GhostIconStyle: Equatable, Hashable {
    case resting
    case awake
    case stealth
    case pendingRestore

    public static func from(sessionMode: SessionMode, isLidClosed: Bool) -> GhostIconStyle {
        switch sessionMode {
        case .idle:
            return .resting
        case .pendingSleepRestore:
            return .pendingRestore
        case .activeFinite, .activeIndefinite:
            return isLidClosed ? .stealth : .awake
        }
    }

    public var cacheKey: String {
        switch self {
        case .resting: return "ghost.resting"
        case .awake: return "ghost.awake"
        case .stealth: return "ghost.stealth"
        case .pendingRestore: return "ghost.pendingRestore"
        }
    }
}

public enum GhostVectorGeometry {
    public static let canvasSize: CGFloat = 18.0

    public static func bodyPath(stealth: Bool) -> CGPath {
        let centerX: CGFloat = 9.0
        let radius: CGFloat = stealth ? 4.9 : 5.4
        let domeY: CGFloat = stealth ? 6.4 : 7.4
        let hemY: CGFloat = stealth ? 11.8 : 14.1
        let valleyY: CGFloat = stealth ? 13.0 : 15.6
        let k = 0.55228475 * radius

        let leftX = centerX - radius
        let rightX = centerX + radius
        let topY = domeY - radius
        let lobeWidth = (rightX - leftX) / 3.0

        let path = CGMutablePath()
        path.move(to: CGPoint(x: leftX, y: hemY))
        path.addLine(to: CGPoint(x: leftX, y: domeY))
        path.addCurve(
            to: CGPoint(x: centerX, y: topY),
            control1: CGPoint(x: leftX, y: domeY - k),
            control2: CGPoint(x: centerX - k, y: topY)
        )
        path.addCurve(
            to: CGPoint(x: rightX, y: domeY),
            control1: CGPoint(x: centerX + k, y: topY),
            control2: CGPoint(x: rightX, y: domeY - k)
        )
        path.addLine(to: CGPoint(x: rightX, y: hemY))

        let lobeInset = 0.15 * lobeWidth
        for idx in 0..<3 {
            let x0 = rightX - CGFloat(idx) * lobeWidth
            let x1 = rightX - CGFloat(idx + 1) * lobeWidth
            path.addCurve(
                to: CGPoint(x: x1, y: hemY),
                control1: CGPoint(x: x0 - lobeInset, y: valleyY),
                control2: CGPoint(x: x1 + lobeInset, y: valleyY)
            )
        }
        path.closeSubpath()
        return path
    }

    public static func restingClosedEyesPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.15, y: 7.4))
        path.addQuadCurve(to: CGPoint(x: 7.95, y: 7.4), control: CGPoint(x: 7.05, y: 8.5))
        path.move(to: CGPoint(x: 10.05, y: 7.4))
        path.addQuadCurve(to: CGPoint(x: 11.85, y: 7.4), control: CGPoint(x: 10.95, y: 8.5))
        return path
    }

    public static func filledSilhouetteWithCutouts(stealth: Bool) -> CGPath {
        let path = CGMutablePath()
        path.addPath(bodyPath(stealth: stealth))
        if stealth {
            path.addRoundedRect(
                in: CGRect(x: 6.45, y: 5.2, width: 1.7, height: 2.6),
                cornerWidth: 0.85,
                cornerHeight: 0.85
            )
            path.addRoundedRect(
                in: CGRect(x: 9.85, y: 5.2, width: 1.7, height: 2.6),
                cornerWidth: 0.85,
                cornerHeight: 0.85
            )
        } else {
            path.addRoundedRect(
                in: CGRect(x: 6.1, y: 6.0, width: 1.9, height: 3.0),
                cornerWidth: 0.95,
                cornerHeight: 0.95
            )
            path.addRoundedRect(
                in: CGRect(x: 10.0, y: 6.0, width: 1.9, height: 3.0),
                cornerWidth: 0.95,
                cornerHeight: 0.95
            )
        }
        return path
    }

    public static func stealthLidBarPath() -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(
            in: CGRect(x: 2.5, y: 14.4, width: 13.0, height: 1.8),
            cornerWidth: 0.9,
            cornerHeight: 0.9
        )
        return path
    }

    /// Draws the menu-bar ghost glyph (`18x18` coordinate space, top-down flipped context).
    public static func drawGlyph(style: GhostIconStyle, in ctx: CGContext, inkColor: CGColor) {
        ctx.setFillColor(inkColor)
        ctx.setStrokeColor(inkColor)

        switch style {
        case .resting:
            ctx.setLineWidth(1.4)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(bodyPath(stealth: false))
            ctx.strokePath()

            ctx.setLineWidth(1.3)
            ctx.setLineCap(.round)
            ctx.addPath(restingClosedEyesPath())
            ctx.strokePath()

        case .awake:
            ctx.addPath(filledSilhouetteWithCutouts(stealth: false))
            ctx.fillPath(using: .evenOdd)

        case .stealth:
            ctx.addPath(filledSilhouetteWithCutouts(stealth: true))
            ctx.fillPath(using: .evenOdd)

            ctx.addPath(stealthLidBarPath())
            ctx.fillPath(using: .winding)

        case .pendingRestore:
            break
        }
    }
}

public struct GhostNotificationPayload: Equatable {
    public let title: String
    public let subtitle: String?
    public let body: String
    public let requestIdentifier: String
    public let threadIdentifier: String
    public let iconStyle: GhostIconStyle
    public let isTimeSensitive: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        body: String,
        requestIdentifier: String = "com.arpit.ghostmode.session",
        threadIdentifier: String = "session",
        iconStyle: GhostIconStyle = .awake,
        isTimeSensitive: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.requestIdentifier = requestIdentifier
        self.threadIdentifier = threadIdentifier
        self.iconStyle = iconStyle
        self.isTimeSensitive = isTimeSensitive
    }
}

public protocol NotificationSending: AnyObject {
    func requestAuthorizationIfNeeded()
    func send(_ payload: GhostNotificationPayload, playSound: Bool)
    func send(title: String, subtitle: String?, body: String, playSound: Bool)
}

public extension NotificationSending {
    func send(title: String, subtitle: String? = nil, body: String, playSound: Bool = true) {
        send(
            GhostNotificationPayload(title: title, subtitle: subtitle, body: body),
            playSound: playSound
        )
    }
}

// MARK: - Sudoers Policy & Privileged Command Result

public enum SudoersPolicy {
    public static let sudoersDirectory = "/private/etc/sudoers.d"
    public static let ghostModeRulePath = "/private/etc/sudoers.d/ghostmode"
    public static let managedRulePaths: [String] = [ghostModeRulePath]

    private static let forbiddenUsernames: Set<String> = [
        "root", "loginwindow", "_mbsetupuser"
    ]

    public static func validatedUsername(_ raw: String) -> String? {
        guard !raw.isEmpty,
              raw.count <= 64,
              !forbiddenUsernames.contains(raw),
              !raw.hasPrefix("-"),
              !raw.hasPrefix(".") else {
            return nil
        }
        let isValid = raw.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
        return isValid ? raw : nil
    }

    public static func sudoersRuleContent(forValidatedUsername username: String) -> String {
        return """
        # Ghost Mode power management rule - Developed by Arpit
        Cmnd_Alias GHOSTMODE_PMSET = /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -g
        \(username) ALL=(root) NOPASSWD: GHOSTMODE_PMSET
        """
    }

    private static func shellQuoted(_ path: String) -> String {
        let isSafeUnquoted = !path.isEmpty && path.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 47, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
        if isSafeUnquoted {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func installCommand(forUsername rawUsername: String) -> String? {
        guard let username = validatedUsername(rawUsername) else {
            return nil
        }
        let ruleLines = sudoersRuleContent(forValidatedUsername: username)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { shellQuoted(String($0)) }
            .joined(separator: " ")

        return [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; IFS=$' \\t\\n'; umask 077;",
            "[ ! -L /private/etc ] && [ ! -L /private/etc/sudoers.d ] || exit 1;",
            "if [ ! -d /private/etc/sudoers.d ]; then /bin/mkdir -m 0750 /private/etc/sudoers.d || exit 1; fi;",
            "/usr/sbin/chown root:wheel /private/etc/sudoers.d && /bin/chmod 0750 /private/etc/sudoers.d || exit 1;",
            "[ ! -L /private/etc/sudoers.d/ghostmode ] && [ ! -d /private/etc/sudoers.d/ghostmode ] || exit 1;",
            "TMP_DIR=$(/usr/bin/mktemp -d /private/etc/sudoers.d/.ghostmode.XXXXXX) || exit 1;",
            "trap '/bin/rm -rf \"$TMP_DIR\"' EXIT;",
            "/usr/bin/printf '%s\\n' \(ruleLines) > \"$TMP_DIR/ghostmode\" || exit 1;",
            "/bin/chmod 0440 \"$TMP_DIR/ghostmode\" && /usr/sbin/visudo -cf \"$TMP_DIR/ghostmode\" >/dev/null 2>&1 || exit 1;",
            "/usr/sbin/chown root:wheel \"$TMP_DIR/ghostmode\" && /bin/chmod 0440 \"$TMP_DIR/ghostmode\" || exit 1;",
            "/bin/mv -f \"$TMP_DIR/ghostmode\" /private/etc/sudoers.d/ghostmode && [ -f /private/etc/sudoers.d/ghostmode ] && [ ! -L /private/etc/sudoers.d/ghostmode ] || exit 1"
        ].joined(separator: " ")
    }

    public static func revokeCommand(paths: [String] = managedRulePaths) -> String {
        guard !paths.isEmpty else { return "/bin/rm -f" }
        let quotedPaths = paths.map(shellQuoted).joined(separator: " ")
        return "/bin/rm -f \(quotedPaths)"
    }

    public static func hardenedRevokeCommand(paths: [String] = managedRulePaths) -> String {
        guard !paths.isEmpty else {
            return "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; umask 077; exit 0"
        }
        let checks = paths.map { path in
            let q = shellQuoted(path)
            return "[ ! -L \(q) ] && [ ! -d \(q) ]"
        }.joined(separator: " && ")
        let rmCmd = revokeCommand(paths: paths)
        return "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; umask 077; [ ! -L /private/etc ] && [ ! -L /private/etc/sudoers.d ] && \(checks) || exit 1; \(rmCmd)"
    }
}

public enum PrivilegedAction: Equatable {
    case configurePasswordlessSudo(username: String)
    case revokePasswordlessSudo
    case setLidSleepDisabled(Bool)

    public func resolvedCommand() -> String? {
        switch self {
        case .configurePasswordlessSudo(let username):
            return SudoersPolicy.installCommand(forUsername: username)
        case .revokePasswordlessSudo:
            return SudoersPolicy.hardenedRevokeCommand()
        case .setLidSleepDisabled(let disabled):
            return disabled ? "/usr/bin/pmset disablesleep 1" : "/usr/bin/pmset disablesleep 0"
        }
    }
}

public struct PrivilegedCommandResult: Equatable {
    public let success: Bool
    public let cancelled: Bool
    public let errorMessage: String?

    public init(success: Bool, cancelled: Bool, errorMessage: String? = nil) {
        self.success = success
        self.cancelled = cancelled
        self.errorMessage = errorMessage
    }
}

// MARK: - Sudo Feature Availability

public enum SudoFeatureAvailability {
    public static func lackingFeaturesSummary() -> String {
        "Closed-lid keep-awake prompts on start/stop; lid-close Screen Off, App Freeze, and silent behind-lid safety restore are disabled."
    }

    public static func effectiveLidFeatureToggle(storedValue: Bool, sudoConfigured: Bool) -> Bool {
        sudoConfigured && storedValue
    }
}
