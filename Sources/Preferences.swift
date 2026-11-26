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
        public static let preventDisplaySleep = "preventDisplaySleep"
        public static let autoClosePopoverOnStart = "autoClosePopoverOnStart"
        public static let autoStartOnLaunch = "autoStartOnLaunch"

        static let resettableKeys: [String] = [
            defaultDuration,
            turnOffScreenOnLidClose,
            batteryCutoffThreshold,
            batteryCutoffEnabled,
            acOnlyModeEnabled,
            thermalGuardEnabled,
            showCountdownInMenuBar,
            soundNotificationsEnabled,
            showInDock,
            appFreezeOnLidCloseEnabled,
            keepAudioActiveOnLidClose,
            appFreezeWhitelist,
            audioFilterMode,
            audioBlockedApps,
            audioAllowedApps,
            preventDisplaySleep,
            autoClosePopoverOnStart,
            autoStartOnLaunch
        ]
    }

    public static let defaultAppFreezeWhitelist = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty"
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func willChange() {
        objectWillChange.send()
    }

    private func didChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public var defaultDuration: Int {
        get {
            let val = defaults.integer(forKey: Keys.defaultDuration)
            return val > 0 ? val : 3600
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.defaultDuration)
            didChange()
        }
    }

    public var turnOffScreenOnLidClose: Bool {
        get {
            if defaults.object(forKey: Keys.turnOffScreenOnLidClose) == nil { return true }
            return defaults.bool(forKey: Keys.turnOffScreenOnLidClose)
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.turnOffScreenOnLidClose)
            didChange()
        }
    }

    public var batteryCutoffThreshold: Int {
        get {
            if defaults.object(forKey: Keys.batteryCutoffThreshold) == nil { return 10 }
            let val = defaults.integer(forKey: Keys.batteryCutoffThreshold)
            return val > 0 ? val : 10
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.batteryCutoffThreshold)
            didChange()
        }
    }

    public var batteryCutoffEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.batteryCutoffEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.batteryCutoffEnabled)
        }
        set {
            willChange()
            // Intentionally preserve batteryCutoffThreshold when toggling off.
            defaults.set(newValue, forKey: Keys.batteryCutoffEnabled)
            didChange()
        }
    }

    public var acOnlyModeEnabled: Bool {
        get { defaults.bool(forKey: Keys.acOnlyModeEnabled) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.acOnlyModeEnabled)
            didChange()
        }
    }

    public var thermalGuardEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.thermalGuardEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.thermalGuardEnabled)
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.thermalGuardEnabled)
            didChange()
        }
    }

    public var showCountdownInMenuBar: Bool {
        get {
            if defaults.object(forKey: Keys.showCountdownInMenuBar) == nil { return true }
            return defaults.bool(forKey: Keys.showCountdownInMenuBar)
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.showCountdownInMenuBar)
            didChange()
        }
    }

    public var soundNotificationsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.soundNotificationsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.soundNotificationsEnabled)
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.soundNotificationsEnabled)
            didChange()
        }
    }

    public var showInDock: Bool {
        get { defaults.bool(forKey: Keys.showInDock) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.showInDock)
            didChange()
        }
    }

    public var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Keys.hasSeenWelcome) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.hasSeenWelcome)
            didChange()
        }
    }

    public var appFreezeOnLidCloseEnabled: Bool {
        get { defaults.bool(forKey: Keys.appFreezeOnLidCloseEnabled) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.appFreezeOnLidCloseEnabled)
            didChange()
        }
    }

    public var keepAudioActiveOnLidClose: Bool {
        get {
            if defaults.object(forKey: Keys.keepAudioActiveOnLidClose) == nil { return true }
            return defaults.bool(forKey: Keys.keepAudioActiveOnLidClose)
        }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.keepAudioActiveOnLidClose)
            didChange()
        }
    }

    public var appFreezeWhitelist: [String] {
        get { defaults.stringArray(forKey: Keys.appFreezeWhitelist) ?? Self.defaultAppFreezeWhitelist }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.appFreezeWhitelist)
            didChange()
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
            willChange()
            defaults.set(newValue.rawValue, forKey: Keys.audioFilterMode)
            didChange()
        }
    }

    public var audioBlockedApps: [String] {
        get { defaults.stringArray(forKey: Keys.audioBlockedApps) ?? [] }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.audioBlockedApps)
            didChange()
        }
    }

    public var audioAllowedApps: [String] {
        get { defaults.stringArray(forKey: Keys.audioAllowedApps) ?? [] }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.audioAllowedApps)
            didChange()
        }
    }

    public var preventDisplaySleep: Bool {
        get { defaults.bool(forKey: Keys.preventDisplaySleep) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.preventDisplaySleep)
            didChange()
        }
    }

    public var autoClosePopoverOnStart: Bool {
        get { defaults.bool(forKey: Keys.autoClosePopoverOnStart) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.autoClosePopoverOnStart)
            didChange()
        }
    }

    public var autoStartOnLaunch: Bool {
        get { defaults.bool(forKey: Keys.autoStartOnLaunch) }
        set {
            willChange()
            defaults.set(newValue, forKey: Keys.autoStartOnLaunch)
            didChange()
        }
    }

    public func resetToDefaults() {
        willChange()
        for key in Keys.resettableKeys {
            defaults.removeObject(forKey: key)
        }
        didChange()
    }
}
