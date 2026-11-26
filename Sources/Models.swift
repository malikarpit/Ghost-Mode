//
//  Models.swift
//  Ghost Mode
//

import AppKit
import Darwin
import Foundation

// MARK: - App Metadata & Signature

public struct AppMetadata {
    public static let name = "Ghost Mode"
    public static let version = "2.2"
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

    public init(
        id: String,
        pid: pid_t,
        name: String,
        bundleIdentifier: String?,
        icon: NSImage? = nil,
        isPlayingAudio: Bool = false,
        isFrozen: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.isPlayingAudio = isPlayingAudio
        self.isFrozen = isFrozen
    }

    public static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id &&
            lhs.pid == rhs.pid &&
            lhs.name == rhs.name &&
            lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.isPlayingAudio == rhs.isPlayingAudio &&
            lhs.isFrozen == rhs.isFrozen
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

public protocol NotificationSending: AnyObject {
    func requestAuthorizationIfNeeded()
    func send(title: String, subtitle: String?, body: String, playSound: Bool)
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
