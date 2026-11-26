//
//  GhostModeViewModel.swift
//  Ghost Mode
//

import AppKit
import Combine
import Foundation
import ServiceManagement

public enum PopoverTab: String, CaseIterable, Identifiable {
    case session
    case safety
    case prefs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .session: return "Session"
        case .safety: return "Safety"
        case .prefs: return "Settings"
        }
    }
}

public struct InlineBanner: Equatable, Identifiable {
    public enum Kind: Equatable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let message: String

    public init(id: UUID = UUID(), kind: Kind, title: String = "", message: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
    }
}

@MainActor
public final class GhostModeViewModel: ObservableObject {
    @Published public var sessionMode: SessionMode = .idle
    @Published public var snapshot: SystemSnapshot
    @Published public var runningApps: [AppEntry] = []
    @Published public var audioRuleApps: [AppEntry] = []
    @Published public var selectedTab: PopoverTab = .session
    @Published public var inlineBanner: InlineBanner?
    @Published public var isPopoverVisible: Bool = false
    @Published public var needsLoginApproval: Bool = false
    @Published public var ghostCPU: Double = 0.0
    @Published public var ghostMemMB: Double = 0.0

    public let preferences: Preferences

    // Action callbacks wired by AppDelegate / StatusBarController
    public var onStartSession: ((Int) -> Void)?
    public var onStopSession: (() -> Void)?
    public var onExtendSession: ((Int) -> Void)?
    public var onTurnOffScreen: (() -> Void)?
    public var onScreenSaver: (() -> Void)?
    public var onUnfreezeAll: (() -> Void)?
    public var onCopyDiagnostics: (() -> Void)?
    public var onResetDefaults: (() -> Void)?
    public var onDisplayPreferenceChanged: (() -> Void)?
    public var onSafetyPreferenceChanged: (() -> Void)?
    public var onFreezePreferenceChanged: (() -> Void)?
    public var onSetupOrRevokeSudo: (() -> Void)?
    public var onToggleDock: (() -> Void)?
    public var onToggleLogin: (() -> Void)?
    public var onToggleCountdown: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onFocusPopover: (() -> Void)?
    public var onSelectedTabChanged: ((PopoverTab) -> Void)?

    public init(
        preferences: Preferences = .shared,
        snapshot: SystemSnapshot = SystemSnapshot(
            hasLid: false,
            isLidClosed: false,
            battery: nil,
            thermalState: .nominal,
            kernelSleepDisabled: false,
            sudoConfigured: false
        )
    ) {
        self.preferences = preferences
        self.snapshot = snapshot
    }

    // MARK: - Session Actions

    public func startDefaultSession() {
        onStartSession?(preferences.defaultDuration)
    }

    public func startSession(seconds: Int) {
        onStartSession?(seconds)
    }

    public func stopSession() {
        onStopSession?()
    }

    public func extendSession(seconds: Int) {
        onExtendSession?(seconds)
    }

    public func turnOffScreen() {
        onTurnOffScreen?()
    }

    public func startScreenSaver() {
        onScreenSaver?()
    }

    public func unfreezeAllNow() {
        onUnfreezeAll?()
    }

    public func copyDiagnostics() {
        onCopyDiagnostics?()
    }

    public func resetDefaults() {
        onResetDefaults?()
    }

    public func focusPopover() {
        onFocusPopover?()
    }

    public func showBanner(_ kind: InlineBanner.Kind, title: String, message: String) {
        inlineBanner = InlineBanner(kind: kind, title: title, message: message)
    }

    public func dismissBanner() {
        inlineBanner = nil
    }

    // MARK: - Safety & Lid Preferences

    public func setACOnlyMode(_ enabled: Bool) {
        preferences.acOnlyModeEnabled = enabled
        onSafetyPreferenceChanged?()
    }

    public func setBatteryCutoffEnabled(_ enabled: Bool) {
        preferences.batteryCutoffEnabled = enabled
        onSafetyPreferenceChanged?()
    }

    public func setBatteryCutoffThreshold(_ threshold: Int) {
        let clamped = max(1, min(50, threshold))
        preferences.batteryCutoffThreshold = clamped
        if !preferences.batteryCutoffEnabled {
            preferences.batteryCutoffEnabled = true
        }
        onSafetyPreferenceChanged?()
    }

    public func setThermalGuardEnabled(_ enabled: Bool) {
        preferences.thermalGuardEnabled = enabled
        onSafetyPreferenceChanged?()
    }

    public func setTurnOffScreenOnLidClose(_ enabled: Bool) {
        preferences.turnOffScreenOnLidClose = enabled
        onFreezePreferenceChanged?()
    }

    public func setPreventDisplaySleep(_ enabled: Bool) {
        preferences.preventDisplaySleep = enabled
        onDisplayPreferenceChanged?()
    }

    public func setAppFreezeEnabled(_ enabled: Bool) {
        preferences.appFreezeOnLidCloseEnabled = enabled
        onFreezePreferenceChanged?()
    }

    public func setKeepAudioActive(_ enabled: Bool) {
        preferences.keepAudioActiveOnLidClose = enabled
        onFreezePreferenceChanged?()
    }

    // MARK: - App Freeze Whitelist

    public func isAppFreezeWhitelisted(_ app: AppEntry) -> Bool {
        let whitelist = Set(preferences.appFreezeWhitelist)
        if let bid = app.bundleIdentifier, whitelist.contains(bid) {
            return true
        }
        return whitelist.contains(app.name)
    }

    public func toggleAppFreezeWhitelist(_ app: AppEntry) {
        let key = app.bundleIdentifier ?? app.name
        var list = preferences.appFreezeWhitelist
        if isAppFreezeWhitelisted(app) {
            list.removeAll { $0 == key || $0 == app.name || (app.bundleIdentifier != nil && $0 == app.bundleIdentifier) }
        } else {
            list.append(key)
        }
        preferences.appFreezeWhitelist = list
        onFreezePreferenceChanged?()
    }

    public func whitelistAllRunningApps() {
        var list = preferences.appFreezeWhitelist
        var existing = Set(list)
        for app in runningApps {
            let key = app.bundleIdentifier ?? app.name
            let alreadyWhitelisted = existing.contains(key) ||
                existing.contains(app.name) ||
                (app.bundleIdentifier != nil && existing.contains(app.bundleIdentifier!))
            if !alreadyWhitelisted {
                list.append(key)
                existing.insert(key)
            }
        }
        preferences.appFreezeWhitelist = list
        onFreezePreferenceChanged?()
    }

    public func clearAppFreezeWhitelist() {
        preferences.appFreezeWhitelist = []
        onFreezePreferenceChanged?()
    }

    public func removeAppFreezeWhitelistIdentifier(_ identifier: String) {
        var list = preferences.appFreezeWhitelist
        list.removeAll { $0 == identifier }
        preferences.appFreezeWhitelist = list
        onFreezePreferenceChanged?()
    }

    public func savedNotRunningWhitelistEntries() -> [SavedRuleEntry] {
        savedNotRunningEntries(from: preferences.appFreezeWhitelist)
    }

    public func savedNotRunningAudioEntries() -> [SavedRuleEntry] {
        let source = preferences.audioFilterMode == .allowAllExceptBlocked
            ? preferences.audioBlockedApps
            : preferences.audioAllowedApps
        return savedNotRunningEntries(from: source, excluding: audioRuleApps)
    }

    public func removeAudioRuleIdentifier(_ identifier: String) {
        switch preferences.audioFilterMode {
        case .allowAllExceptBlocked:
            var blocked = preferences.audioBlockedApps
            blocked.removeAll { $0 == identifier }
            preferences.audioBlockedApps = blocked
        case .allowOnlySelected:
            var allowed = preferences.audioAllowedApps
            allowed.removeAll { $0 == identifier }
            preferences.audioAllowedApps = allowed
        }
        onFreezePreferenceChanged?()
    }

    private func savedNotRunningEntries(from identifiers: [String], excluding extraApps: [AppEntry] = []) -> [SavedRuleEntry] {
        let runningKeys = Set((runningApps + extraApps).flatMap { entry -> [String] in
            if let bid = entry.bundleIdentifier, !bid.isEmpty {
                return [bid, entry.name]
            }
            return [entry.name]
        })
        return identifiers
            .filter { !runningKeys.contains($0) }
            .map(resolveSavedRuleEntry)
    }

    private func resolveSavedRuleEntry(_ identifier: String) -> SavedRuleEntry {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            let bundleName = (Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
            return SavedRuleEntry(identifier: identifier, displayName: bundleName, icon: icon)
        }
        let fallbackName: String
        if identifier.contains(".") {
            let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
            fallbackName = tail.prefix(1).uppercased() + tail.dropFirst()
        } else {
            fallbackName = identifier
        }
        return SavedRuleEntry(identifier: identifier, displayName: fallbackName, icon: nil)
    }

    // MARK: - Audio Filter Rules

    public func audioRuleDisplayState(for app: AppEntry) -> AudioRuleDisplayState {
        AudioAppCatalog.effectiveAudioRuleState(
            bundleID: app.bundleIdentifier,
            appName: app.name,
            whitelist: Set(preferences.appFreezeWhitelist),
            mode: preferences.audioFilterMode,
            blockedApps: preferences.audioBlockedApps,
            allowedApps: preferences.audioAllowedApps
        )
    }

    public func isAudioAppAllowed(_ app: AppEntry) -> Bool {
        AppFreezer.isAudioAllowed(
            bundleID: app.bundleIdentifier,
            appName: app.name,
            mode: preferences.audioFilterMode,
            blockedApps: preferences.audioBlockedApps,
            allowedApps: preferences.audioAllowedApps
        )
    }

    public func toggleAudioApp(_ app: AppEntry) {
        if isAppFreezeWhitelisted(app) {
            return
        }
        let key = app.bundleIdentifier ?? app.name
        switch preferences.audioFilterMode {
        case .allowAllExceptBlocked:
            var blocked = preferences.audioBlockedApps
            let isBlocked = blocked.contains(key) || blocked.contains(app.name) ||
                (app.bundleIdentifier != nil && blocked.contains(app.bundleIdentifier!))
            if isBlocked {
                blocked.removeAll { $0 == key || $0 == app.name || (app.bundleIdentifier != nil && $0 == app.bundleIdentifier) }
            } else {
                blocked.append(key)
            }
            preferences.audioBlockedApps = blocked

        case .allowOnlySelected:
            var allowed = preferences.audioAllowedApps
            let isAllowed = allowed.contains(key) || allowed.contains(app.name) ||
                (app.bundleIdentifier != nil && allowed.contains(app.bundleIdentifier!))
            if isAllowed {
                allowed.removeAll { $0 == key || $0 == app.name || (app.bundleIdentifier != nil && $0 == app.bundleIdentifier) }
            } else {
                allowed.append(key)
            }
            preferences.audioAllowedApps = allowed
        }
        onFreezePreferenceChanged?()
    }

    public func setAudioFilterMode(_ mode: AudioFilterMode) {
        preferences.audioFilterMode = mode
        onFreezePreferenceChanged?()
    }

    public func resetAudioRulesToAllowAll() {
        preferences.audioFilterMode = .allowAllExceptBlocked
        preferences.audioBlockedApps = []
        preferences.audioAllowedApps = []
        onFreezePreferenceChanged?()
    }

    public var isDefaultAllowAllAudio: Bool {
        preferences.audioFilterMode == .allowAllExceptBlocked && preferences.audioBlockedApps.isEmpty
    }

    public var audioSummaryLabel: String {
        switch preferences.audioFilterMode {
        case .allowAllExceptBlocked:
            let blockedCount = preferences.audioBlockedApps.count
            return blockedCount == 0 ? "All audio apps allowed" : "Blocked (\(blockedCount))"
        case .allowOnlySelected:
            return "Selected (\(preferences.audioAllowedApps.count))"
        }
    }

    // MARK: - General Preferences & App Actions

    public func setDefaultDuration(_ seconds: Int) {
        preferences.defaultDuration = seconds
    }

    public func setShowCountdown(_ enabled: Bool) {
        preferences.showCountdownInMenuBar = enabled
        onToggleCountdown?()
    }

    public func setSoundNotifications(_ enabled: Bool) {
        preferences.soundNotificationsEnabled = enabled
    }

    public func setShowInDock(_ enabled: Bool) {
        preferences.showInDock = enabled
        onToggleDock?()
    }

    public func setAutoClosePopover(_ enabled: Bool) {
        preferences.autoClosePopoverOnStart = enabled
    }

    public func setAutoStartOnLaunch(_ enabled: Bool) {
        preferences.autoStartOnLaunch = enabled
    }

    public func toggleLoginItem() {
        onToggleLogin?()
    }

    public func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    public func setupOrRevokeSudo() {
        onSetupOrRevokeSudo?()
    }

    public func openGitHub() {
        if let url = URL(string: AppMetadata.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }
    }

    public func openReportBug() {
        if let url = URL(string: AppMetadata.reportURL) {
            NSWorkspace.shared.open(url)
        }
    }

    public func quitApp() {
        onQuit?()
    }
}
