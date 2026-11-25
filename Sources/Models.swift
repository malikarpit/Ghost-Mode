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
    public static let version = "2.0"
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

    public init(percent: Int, isCharging: Bool, isAC: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.isAC = isAC
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

    public init(
        id: String,
        pid: pid_t,
        name: String,
        bundleIdentifier: String?,
        icon: NSImage? = nil,
        isPlayingAudio: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.isPlayingAudio = isPlayingAudio
    }

    public static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id &&
            lhs.pid == rhs.pid &&
            lhs.name == rhs.name &&
            lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.isPlayingAudio == rhs.isPlayingAudio
    }
}

public struct SystemSnapshot: Equatable {
    public let hasLid: Bool
    public let isLidClosed: Bool
    public let battery: BatteryStatus?
    public let thermalState: ProcessInfo.ThermalState
    public let kernelSleepDisabled: Bool
    public let sudoConfigured: Bool

    public init(
        hasLid: Bool,
        isLidClosed: Bool,
        battery: BatteryStatus?,
        thermalState: ProcessInfo.ThermalState,
        kernelSleepDisabled: Bool,
        sudoConfigured: Bool
    ) {
        self.hasLid = hasLid
        self.isLidClosed = isLidClosed
        self.battery = battery
        self.thermalState = thermalState
        self.kernelSleepDisabled = kernelSleepDisabled
        self.sudoConfigured = sudoConfigured
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
