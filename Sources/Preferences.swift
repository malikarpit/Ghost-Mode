//
//  Preferences.swift
//  Ghost Mode
//

import Combine
import Foundation

public final class Preferences: ObservableObject {
    public static let shared = Preferences()
    public static let didChangeNotification = Notification.Name("com.arpit.ghostmode.preferencesDidChange")

    private let defaults: UserDefaults

    public enum Keys {
        public static let defaultDuration = "defaultDuration"
        public static let turnOffScreenOnLidClose = "turnOffScreenOnLidClose"
        public static let batteryCutoffThreshold = "batteryCutoffThreshold"
        public static let batteryCutoffEnabled = "batteryCutoffEnabled"
        public static let acOnlyModeEnabled = "acOnlyModeEnabled"
        public static let thermalGuardEnabled = "thermalGuardEnabled"
        public static let showCountdownInMenuBar = "showCountdownInMenuBar"
        public static let soundNotificationsEnabled = "soundNotificationsEnabled"
        public static let showInDock = "showInDock"
        public static let hasSeenWelcome = "hasSeenWelcome"
        public static let appFreezeOnLidCloseEnabled = "appFreezeOnLidCloseEnabled"
        public static let keepAudioActiveOnLidClose = "keepAudioActiveOnLidClose"
        public static let appFreezeWhitelist = "appFreezeWhitelist"
        public static let audioFilterMode = "audioFilterMode"
        public static let audioBlockedApps = "audioBlockedApps"
        public static let audioAllowedApps = "audioAllowedApps"

        // Legacy & migration keys
        public static let legacyAudioAppWhitelist = "audioAppWhitelist"
        public static let didMigrateAudioWhitelistV2 = "didMigrateAudioWhitelistV2"
    }

    public static let defaultAppFreezeWhitelist = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty"
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyAudioWhitelistIfNeeded()
    }

    private func migrateLegacyAudioWhitelistIfNeeded() {
        guard !defaults.bool(forKey: Keys.didMigrateAudioWhitelistV2) else { return }

        if let legacyWhitelist = defaults.stringArray(forKey: Keys.legacyAudioAppWhitelist) {
            if !legacyWhitelist.isEmpty {
                defaults.set(legacyWhitelist, forKey: Keys.audioAllowedApps)
                defaults.set(AudioFilterMode.allowOnlySelected.rawValue, forKey: Keys.audioFilterMode)
            } else if defaults.string(forKey: Keys.audioFilterMode) == nil {
                defaults.set(AudioFilterMode.allowAllExceptBlocked.rawValue, forKey: Keys.audioFilterMode)
            }
        }

        defaults.set(true, forKey: Keys.didMigrateAudioWhitelistV2)
    }

    private func notifyChange() {
        objectWillChange.send()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public var defaultDuration: Int {
        get {
            let val = defaults.integer(forKey: Keys.defaultDuration)
            return val > 0 ? val : 3600
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.defaultDuration)
        }
    }

    public var turnOffScreenOnLidClose: Bool {
        get {
            if defaults.object(forKey: Keys.turnOffScreenOnLidClose) == nil { return true }
            return defaults.bool(forKey: Keys.turnOffScreenOnLidClose)
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.turnOffScreenOnLidClose)
        }
    }

    public var batteryCutoffThreshold: Int {
        get {
            if defaults.object(forKey: Keys.batteryCutoffThreshold) == nil { return 10 }
            let val = defaults.integer(forKey: Keys.batteryCutoffThreshold)
            return val > 0 ? val : 10
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.batteryCutoffThreshold)
        }
    }

    public var batteryCutoffEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.batteryCutoffEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.batteryCutoffEnabled)
        }
        set {
            notifyChange()
            // Intentionally preserve batteryCutoffThreshold when toggling off.
            defaults.set(newValue, forKey: Keys.batteryCutoffEnabled)
        }
    }

    public var acOnlyModeEnabled: Bool {
        get { defaults.bool(forKey: Keys.acOnlyModeEnabled) }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.acOnlyModeEnabled)
        }
    }

    public var thermalGuardEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.thermalGuardEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.thermalGuardEnabled)
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.thermalGuardEnabled)
        }
    }

    public var showCountdownInMenuBar: Bool {
        get {
            if defaults.object(forKey: Keys.showCountdownInMenuBar) == nil { return true }
            return defaults.bool(forKey: Keys.showCountdownInMenuBar)
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.showCountdownInMenuBar)
        }
    }

    public var soundNotificationsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.soundNotificationsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.soundNotificationsEnabled)
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.soundNotificationsEnabled)
        }
    }

    public var showInDock: Bool {
        get { defaults.bool(forKey: Keys.showInDock) }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.showInDock)
        }
    }

    public var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Keys.hasSeenWelcome) }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.hasSeenWelcome)
        }
    }

    public var appFreezeOnLidCloseEnabled: Bool {
        get { defaults.bool(forKey: Keys.appFreezeOnLidCloseEnabled) }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.appFreezeOnLidCloseEnabled)
        }
    }

    public var keepAudioActiveOnLidClose: Bool {
        get {
            if defaults.object(forKey: Keys.keepAudioActiveOnLidClose) == nil { return true }
            return defaults.bool(forKey: Keys.keepAudioActiveOnLidClose)
        }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.keepAudioActiveOnLidClose)
        }
    }

    public var appFreezeWhitelist: [String] {
        get { defaults.stringArray(forKey: Keys.appFreezeWhitelist) ?? Self.defaultAppFreezeWhitelist }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.appFreezeWhitelist)
        }
    }

    public var audioFilterMode: AudioFilterMode {
        get {
            guard let raw = defaults.string(forKey: Keys.audioFilterMode),
                  let mode = AudioFilterMode(rawValue: raw) else {
                return .allowAllExceptBlocked
            }
            return mode
        }
        set {
            notifyChange()
            defaults.set(newValue.rawValue, forKey: Keys.audioFilterMode)
        }
    }

    public var audioBlockedApps: [String] {
        get { defaults.stringArray(forKey: Keys.audioBlockedApps) ?? [] }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.audioBlockedApps)
        }
    }

    public var audioAllowedApps: [String] {
        get { defaults.stringArray(forKey: Keys.audioAllowedApps) ?? [] }
        set {
            notifyChange()
            defaults.set(newValue, forKey: Keys.audioAllowedApps)
        }
    }
}
