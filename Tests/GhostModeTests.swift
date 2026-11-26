//
//  GhostModeTests.swift
//  Ghost Mode
//

import Foundation
import IOKit.ps

@main
struct GhostModeTestRunner {
    private static var passed = 0
    private static var failed = 0
    private static var failures: [String] = []

    static func main() {
        testDurationHelpers()
        testSessionModeProperties()
        testPreferences()
        testPowerSnapshotParser()
        testSafetyEvaluator()
        testAppFreezerPureHelpers()
        testSudoersPolicyAndPrivilegedResult()
        testSudoFeatureAvailability()

        print("")
        print("Ghost Mode Unit Tests Summary: \(passed) passed, \(failed) failed")
        if !failures.isEmpty {
            print("Failures:")
            for failure in failures {
                print("  - \(failure)")
            }
            exit(1)
        }
        exit(0)
    }

    // MARK: - Assertions

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        line: Int = #line
    ) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            let entry = "Line \(line): \(message)"
            failures.append(entry)
            print("FAIL [\(entry)]")
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String,
        line: Int = #line
    ) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            let entry = "Line \(line): \(message) — expected \(expected), got \(actual)"
            failures.append(entry)
            print("FAIL [\(entry)]")
        }
    }

    private static func expectNil<T>(
        _ value: T?,
        _ message: String,
        line: Int = #line
    ) {
        if value == nil {
            passed += 1
        } else {
            failed += 1
            let entry = "Line \(line): \(message) — expected nil, got \(String(describing: value))"
            failures.append(entry)
            print("FAIL [\(entry)]")
        }
    }

    private static func withIsolatedPreferences(_ body: (Preferences, UserDefaults) -> Void) {
        let suiteName = "com.arpit.GhostMode.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failed += 1
            failures.append("Unable to create isolated UserDefaults suite \(suiteName)")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let prefs = Preferences(defaults: defaults)
        body(prefs, defaults)
    }

    // MARK: - DurationHelpers

    private static func testDurationHelpers() {
        expectEqual(parseDurationString("90m"), 5400, "parseDurationString 90m")
        expectEqual(parseDurationString("1.5h"), 5400, "parseDurationString 1.5h")
        expectEqual(parseDurationString("45"), 2700, "parseDurationString bare 45 defaults to minutes")
        expectEqual(parseDurationString("1h 30m 15s"), 5415, "parseDurationString compound")
        expectEqual(parseDurationString("0"), 0, "parseDurationString 0")
        expectNil(parseDurationString(""), "parseDurationString empty")
        expectNil(parseDurationString("   "), "parseDurationString whitespace")
        expectNil(parseDurationString("-15m"), "parseDurationString negative")
        expectNil(parseDurationString("invalid"), "parseDurationString invalid text")
        expectNil(parseDurationString("99999999999999999h"), "parseDurationString overflow")

        expectEqual(formatDurationHuman(0), "Indefinite", "formatDurationHuman 0")
        expectEqual(formatDurationHuman(-1), "Indefinite", "formatDurationHuman negative")
        expectEqual(formatDurationHuman(5400), "1h 30m", "formatDurationHuman 90m")
        expectEqual(formatDurationHuman(3600), "1h", "formatDurationHuman 1h")
        expectEqual(formatDurationHuman(125), "2m 5s", "formatDurationHuman <5m with seconds")
        expectEqual(formatDurationHuman(600), "10m", "formatDurationHuman 10m")
        expectEqual(formatDurationHuman(45), "45s", "formatDurationHuman 45s")

        expectEqual(formatCountdown(0), "00:00", "formatCountdown 0")
        expectEqual(formatCountdown(-5), "00:00", "formatCountdown negative")
        expectEqual(formatCountdown(5405), "1h 30m 05s", "formatCountdown hours")
        expectEqual(formatCountdown(3600), "1h 00m 00s", "formatCountdown exact 1h")
        expectEqual(formatCountdown(65), "01:05", "formatCountdown mm:ss")

        expectEqual(formatDurationCompact(0), "0s", "formatDurationCompact 0")
        expectEqual(formatDurationCompact(-1), "0s", "formatDurationCompact negative")
        expectEqual(formatDurationCompact(5400), "1h 30m", "formatDurationCompact 1h 30m")
        expectEqual(formatDurationCompact(3600), "1h", "formatDurationCompact 1h")
        expectEqual(formatDurationCompact(1800), "30m", "formatDurationCompact 30m")
        expectEqual(formatDurationCompact(45), "45s", "formatDurationCompact 45s")
    }

    // MARK: - SessionMode

    private static func testSessionModeProperties() {
        let idle = SessionMode.idle
        expectEqual(idle.isActive, false, "idle.isActive")
        expectEqual(idle.isIndefinite, false, "idle.isIndefinite")
        expectNil(idle.endDate, "idle.endDate")
        expectNil(idle.totalDuration, "idle.totalDuration")

        let targetDate = Date(timeIntervalSince1970: 1_800_000_000)
        let finite = SessionMode.activeFinite(endDate: targetDate, totalDuration: 1800)
        expectEqual(finite.isActive, true, "finite.isActive")
        expectEqual(finite.isIndefinite, false, "finite.isIndefinite")
        expectEqual(finite.endDate, targetDate, "finite.endDate")
        expectEqual(finite.totalDuration, 1800, "finite.totalDuration")

        let indefinite = SessionMode.activeIndefinite
        expectEqual(indefinite.isActive, true, "indefinite.isActive")
        expectEqual(indefinite.isIndefinite, true, "indefinite.isIndefinite")
        expectNil(indefinite.endDate, "indefinite.endDate")
        expectNil(indefinite.totalDuration, "indefinite.totalDuration")

        let pending = SessionMode.pendingSleepRestore(.lowBattery(percent: 10))
        expectEqual(pending.isActive, false, "pending.isActive")
        expectEqual(pending.isIndefinite, false, "pending.isIndefinite")
        expectNil(pending.endDate, "pending.endDate")
        expectNil(pending.totalDuration, "pending.totalDuration")
    }

    // MARK: - Preferences

    private static func testPreferences() {
        // 1. Default values and threshold preservation on toggle off
        withIsolatedPreferences { prefs, defaults in
            expectEqual(prefs.defaultDuration, 3600, "default defaultDuration")
            expectEqual(prefs.turnOffScreenOnLidClose, true, "default turnOffScreenOnLidClose")
            expectEqual(prefs.batteryCutoffThreshold, 10, "default batteryCutoffThreshold")
            expectEqual(prefs.batteryCutoffEnabled, true, "default batteryCutoffEnabled")
            expectEqual(prefs.acOnlyModeEnabled, false, "default acOnlyModeEnabled")
            expectEqual(prefs.thermalGuardEnabled, true, "default thermalGuardEnabled")
            expectEqual(prefs.showCountdownInMenuBar, true, "default showCountdownInMenuBar")
            expectEqual(prefs.soundNotificationsEnabled, true, "default soundNotificationsEnabled")
            expectEqual(prefs.showInDock, false, "default showInDock")
            expectEqual(prefs.hasSeenWelcome, false, "default hasSeenWelcome")
            expectEqual(prefs.appFreezeOnLidCloseEnabled, false, "default appFreezeOnLidCloseEnabled")
            expectEqual(prefs.keepAudioActiveOnLidClose, true, "default keepAudioActiveOnLidClose")
            expectEqual(prefs.appFreezeWhitelist, Preferences.defaultAppFreezeWhitelist, "default appFreezeWhitelist")
            expectEqual(prefs.audioFilterMode, .allowAllExceptBlocked, "default audioFilterMode")
            expectEqual(prefs.audioBlockedApps, [], "default audioBlockedApps")
            expectEqual(prefs.audioAllowedApps, [], "default audioAllowedApps")
            expectEqual(prefs.preventDisplaySleep, false, "default preventDisplaySleep")
            expectEqual(prefs.autoClosePopoverOnStart, false, "default autoClosePopoverOnStart")
            expectEqual(prefs.autoStartOnLaunch, false, "default autoStartOnLaunch")

            prefs.batteryCutoffThreshold = 15
            prefs.batteryCutoffEnabled = false
            expectEqual(prefs.batteryCutoffEnabled, false, "batteryCutoffEnabled toggled off")
            expectEqual(prefs.batteryCutoffThreshold, 15, "batteryCutoffThreshold preserved after toggle off")
            expectEqual(
                defaults.integer(forKey: Preferences.Keys.batteryCutoffThreshold),
                15,
                "defaults preserves batteryCutoffThreshold"
            )
            prefs.batteryCutoffEnabled = true
            expectEqual(prefs.batteryCutoffThreshold, 15, "batteryCutoffThreshold still 15 on re-enable")
        }

        // 2. Default Preferences reset check on isolated UserDefaults suite
        withIsolatedPreferences { prefs, _ in
            prefs.audioFilterMode = .allowOnlySelected
            prefs.audioAllowedApps = ["com.spotify.client"]
            prefs.resetToDefaults()
            expectEqual(prefs.audioFilterMode, .allowAllExceptBlocked, "reset restores allowAllExceptBlocked")
            expectEqual(prefs.audioAllowedApps, [], "reset clears audioAllowedApps")
        }

        // 3. didChangeNotification fires AFTER defaults reflects the new value
        withIsolatedPreferences { prefs, defaults in
            var observedAcOnlyDuringNotification: Bool?
            var observedThresholdDuringNotification: Int?
            var notificationCount = 0

            let token = NotificationCenter.default.addObserver(
                forName: Preferences.didChangeNotification,
                object: prefs,
                queue: nil
            ) { _ in
                notificationCount += 1
                if notificationCount == 1 {
                    observedAcOnlyDuringNotification = defaults.bool(forKey: Preferences.Keys.acOnlyModeEnabled)
                } else if notificationCount == 2 {
                    observedThresholdDuringNotification = defaults.integer(forKey: Preferences.Keys.batteryCutoffThreshold)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            prefs.acOnlyModeEnabled = true
            prefs.batteryCutoffThreshold = 25

            expectEqual(notificationCount, 2, "didChangeNotification count")
            expectEqual(observedAcOnlyDuringNotification, true, "defaults reflects acOnlyModeEnabled when notification fires")
            expectEqual(observedThresholdDuringNotification, 25, "defaults reflects batteryCutoffThreshold when notification fires")
        }

        // 5. New preferences persistence & resetToDefaults() preserving hasSeenWelcome
        withIsolatedPreferences { prefs, defaults in
            prefs.hasSeenWelcome = true
            prefs.defaultDuration = 7200
            prefs.turnOffScreenOnLidClose = false
            prefs.batteryCutoffThreshold = 25
            prefs.batteryCutoffEnabled = false
            prefs.acOnlyModeEnabled = true
            prefs.thermalGuardEnabled = false
            prefs.showCountdownInMenuBar = false
            prefs.soundNotificationsEnabled = false
            prefs.showInDock = true
            prefs.appFreezeOnLidCloseEnabled = true
            prefs.keepAudioActiveOnLidClose = false
            prefs.appFreezeWhitelist = ["com.example.app"]
            prefs.audioFilterMode = .allowOnlySelected
            prefs.audioBlockedApps = ["com.blocked.app"]
            prefs.audioAllowedApps = ["com.allowed.app"]
            prefs.preventDisplaySleep = true
            prefs.autoClosePopoverOnStart = true
            prefs.autoStartOnLaunch = true

            expectEqual(prefs.preventDisplaySleep, true, "preventDisplaySleep persists true")
            expectEqual(prefs.autoClosePopoverOnStart, true, "autoClosePopoverOnStart persists true")
            expectEqual(prefs.autoStartOnLaunch, true, "autoStartOnLaunch persists true")

            var resetNotificationCount = 0
            let token = NotificationCenter.default.addObserver(
                forName: Preferences.didChangeNotification,
                object: prefs,
                queue: nil
            ) { _ in
                resetNotificationCount += 1
            }
            defer { NotificationCenter.default.removeObserver(token) }

            prefs.resetToDefaults()

            expectEqual(resetNotificationCount, 1, "resetToDefaults posts didChangeNotification")
            expectEqual(prefs.hasSeenWelcome, true, "resetToDefaults preserves hasSeenWelcome")
            expectEqual(prefs.defaultDuration, 3600, "resetToDefaults restores defaultDuration")
            expectEqual(prefs.turnOffScreenOnLidClose, true, "resetToDefaults restores turnOffScreenOnLidClose")
            expectEqual(prefs.batteryCutoffThreshold, 10, "resetToDefaults restores batteryCutoffThreshold")
            expectEqual(prefs.batteryCutoffEnabled, true, "resetToDefaults restores batteryCutoffEnabled")
            expectEqual(prefs.acOnlyModeEnabled, false, "resetToDefaults restores acOnlyModeEnabled")
            expectEqual(prefs.thermalGuardEnabled, true, "resetToDefaults restores thermalGuardEnabled")
            expectEqual(prefs.showCountdownInMenuBar, true, "resetToDefaults restores showCountdownInMenuBar")
            expectEqual(prefs.soundNotificationsEnabled, true, "resetToDefaults restores soundNotificationsEnabled")
            expectEqual(prefs.showInDock, false, "resetToDefaults restores showInDock")
            expectEqual(prefs.appFreezeOnLidCloseEnabled, false, "resetToDefaults restores appFreezeOnLidCloseEnabled")
            expectEqual(prefs.keepAudioActiveOnLidClose, true, "resetToDefaults restores keepAudioActiveOnLidClose")
            expectEqual(prefs.appFreezeWhitelist, Preferences.defaultAppFreezeWhitelist, "resetToDefaults restores appFreezeWhitelist")
            expectEqual(prefs.audioFilterMode, .allowAllExceptBlocked, "resetToDefaults restores audioFilterMode")
            expectEqual(prefs.audioBlockedApps, [], "resetToDefaults restores audioBlockedApps")
            expectEqual(prefs.audioAllowedApps, [], "resetToDefaults restores audioAllowedApps")
            expectEqual(prefs.preventDisplaySleep, false, "resetToDefaults restores preventDisplaySleep")
            expectEqual(prefs.autoClosePopoverOnStart, false, "resetToDefaults restores autoClosePopoverOnStart")
            expectEqual(prefs.autoStartOnLaunch, false, "resetToDefaults restores autoStartOnLaunch")
            expectNil(defaults.object(forKey: Preferences.Keys.preventDisplaySleep), "resetToDefaults removes preventDisplaySleep key")
            expectNil(defaults.object(forKey: Preferences.Keys.defaultDuration), "resetToDefaults removes defaultDuration key")
        }
    }

    // MARK: - PowerSnapshotParser

    private static func testPowerSnapshotParser() {
        let bluetoothAccessory: [String: Any] = [
            kIOPSTypeKey: "Accessory Source",
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 5,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false
        ]
        let upsSource: [String: Any] = [
            kIOPSTypeKey: "UPS",
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 5,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false
        ]
        let internalCharging: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 82,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true
        ]
        let internalDischarging: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 47,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false
        ]
        let absentInternal: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: false,
            kIOPSCurrentCapacityKey: 12,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false
        ]

        let parsedWithPeripheralsFirst = PowerSnapshotParser.parseBatteryStatus(
            sources: [bluetoothAccessory, upsSource, internalCharging],
            providingPowerSource: kIOPSACPowerValue
        )
        expectEqual(
            parsedWithPeripheralsFirst,
            BatteryStatus(percent: 82, isCharging: true, isAC: true),
            "parseBatteryStatus ignores peripheral/UPS at 5% and reads internal battery"
        )

        let parsedOnBattery = PowerSnapshotParser.parseBatteryStatus(
            sources: [internalDischarging],
            providingPowerSource: kIOPSBatteryPowerValue
        )
        expectEqual(
            parsedOnBattery,
            BatteryStatus(percent: 47, isCharging: false, isAC: false),
            "parseBatteryStatus reads discharging internal battery accurately"
        )

        let parsedNoInternal = PowerSnapshotParser.parseBatteryStatus(
            sources: [bluetoothAccessory, upsSource],
            providingPowerSource: kIOPSACPowerValue
        )
        expectNil(parsedNoInternal, "parseBatteryStatus returns nil when no internal battery exists")

        let parsedAbsentInternal = PowerSnapshotParser.parseBatteryStatus(
            sources: [absentInternal],
            providingPowerSource: kIOPSBatteryPowerValue
        )
        expectNil(parsedAbsentInternal, "parseBatteryStatus returns nil when internal battery is not present")

        let parsedEmpty = PowerSnapshotParser.parseBatteryStatus(sources: [], providingPowerSource: nil)
        expectNil(parsedEmpty, "parseBatteryStatus returns nil for empty sources")

        // timeRemainingMinutes parsing: discharging (kIOPSTimeToEmptyKey) & charging (kIOPSTimeToFullChargeKey)
        let dischargingWithTime: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 60,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false,
            kIOPSTimeToEmptyKey: 102,
            kIOPSTimeToFullChargeKey: 99
        ]
        let parsedDischargingWithTime = PowerSnapshotParser.parseBatteryStatus(
            sources: [dischargingWithTime],
            providingPowerSource: kIOPSBatteryPowerValue
        )
        expectEqual(
            parsedDischargingWithTime?.timeRemainingMinutes,
            102,
            "parseBatteryStatus parses kIOPSTimeToEmptyKey when discharging"
        )

        let chargingWithTime: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 75,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true,
            kIOPSTimeToEmptyKey: 300,
            kIOPSTimeToFullChargeKey: 45
        ]
        let parsedChargingWithTime = PowerSnapshotParser.parseBatteryStatus(
            sources: [chargingWithTime],
            providingPowerSource: kIOPSACPowerValue
        )
        expectEqual(
            parsedChargingWithTime?.timeRemainingMinutes,
            45,
            "parseBatteryStatus parses kIOPSTimeToFullChargeKey when charging"
        )

        let dischargingBoundaryMax: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 95,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false,
            kIOPSTimeToEmptyKey: 2400
        ]
        expectEqual(
            PowerSnapshotParser.parseBatteryStatus(sources: [dischargingBoundaryMax], providingPowerSource: nil)?.timeRemainingMinutes,
            2400,
            "parseBatteryStatus accepts upper bound 2400"
        )

        for invalidValue in [-1, 0, 2401] {
            let invalidDischarging: [String: Any] = [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSIsPresentKey: true,
                kIOPSCurrentCapacityKey: 50,
                kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
                kIOPSIsChargingKey: false,
                kIOPSTimeToEmptyKey: invalidValue
            ]
            expectNil(
                PowerSnapshotParser.parseBatteryStatus(sources: [invalidDischarging], providingPowerSource: nil)?.timeRemainingMinutes,
                "parseBatteryStatus ignores out-of-range timeRemainingMinutes \(invalidValue)"
            )
        }

        let acNotChargingWithStaleEmpty: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: false,
            kIOPSTimeToEmptyKey: 120
        ]
        expectNil(
            PowerSnapshotParser.parseBatteryStatus(sources: [acNotChargingWithStaleEmpty], providingPowerSource: kIOPSACPowerValue)?.timeRemainingMinutes,
            "parseBatteryStatus ignores kIOPSTimeToEmptyKey when on AC and not charging"
        )

        // Default model fields remain backwards-compatible
        let defaultSnapshot = SystemSnapshot(
            hasLid: true,
            isLidClosed: false,
            battery: nil,
            thermalState: .nominal,
            kernelSleepDisabled: false,
            sudoConfigured: false
        )
        expectEqual(defaultSnapshot.frozenAppCount, 0, "SystemSnapshot defaults frozenAppCount to 0")

        let unfrozenApp = AppEntry(id: "1", pid: 100, name: "App", bundleIdentifier: "com.test.app")
        let frozenApp = AppEntry(id: "1", pid: 100, name: "App", bundleIdentifier: "com.test.app", isFrozen: true)
        expectEqual(unfrozenApp.isFrozen, false, "AppEntry defaults isFrozen to false")
        expect(unfrozenApp != frozenApp, "AppEntry equality considers isFrozen")
    }

    // MARK: - SafetyEvaluator

    private static func testSafetyEvaluator() {
        let onBattery80 = BatteryStatus(percent: 80, isCharging: false, isAC: false)
        let onAC80 = BatteryStatus(percent: 80, isCharging: true, isAC: true)
        let onBattery15 = BatteryStatus(percent: 15, isCharging: false, isAC: false)
        let onAC15 = BatteryStatus(percent: 15, isCharging: true, isAC: true)

        withIsolatedPreferences { prefs, _ in
            prefs.acOnlyModeEnabled = true
            prefs.batteryCutoffEnabled = false
            prefs.thermalGuardEnabled = false

            expectEqual(
                SafetyEvaluator.evaluate(battery: onBattery80, thermalState: .nominal, preferences: prefs),
                .violation(.unpluggedAC),
                "acOnlyModeEnabled on battery triggers .unpluggedAC"
            )
            expectEqual(
                SafetyEvaluator.evaluate(battery: onAC80, thermalState: .nominal, preferences: prefs),
                .none,
                "acOnlyModeEnabled on AC is safe"
            )
            expectEqual(
                SafetyEvaluator.evaluate(battery: nil, thermalState: .nominal, preferences: prefs),
                .none,
                "acOnlyModeEnabled with nil battery (desktop) is safe"
            )
        }

        withIsolatedPreferences { prefs, _ in
            prefs.acOnlyModeEnabled = false
            prefs.batteryCutoffEnabled = true
            prefs.batteryCutoffThreshold = 15
            prefs.thermalGuardEnabled = false

            expectEqual(
                SafetyEvaluator.evaluate(battery: onBattery15, thermalState: .nominal, preferences: prefs),
                .violation(.lowBattery(percent: 15)),
                "batteryCutoff at 15% on battery triggers .lowBattery(percent: 15)"
            )
            expectEqual(
                SafetyEvaluator.evaluate(battery: onAC15, thermalState: .nominal, preferences: prefs),
                .none,
                "batteryCutoff at 15% on AC is safe"
            )

            prefs.batteryCutoffEnabled = false
            expectEqual(
                SafetyEvaluator.evaluate(battery: onBattery15, thermalState: .nominal, preferences: prefs),
                .none,
                "disabled batteryCutoff ignores 15% battery"
            )
        }

        withIsolatedPreferences { prefs, _ in
            prefs.acOnlyModeEnabled = false
            prefs.batteryCutoffEnabled = false
            prefs.thermalGuardEnabled = true

            expectEqual(
                SafetyEvaluator.evaluate(battery: onAC80, thermalState: .critical, preferences: prefs),
                .violation(.thermalOverheat),
                "thermalGuard .critical triggers .thermalOverheat"
            )
            expectEqual(
                SafetyEvaluator.evaluate(battery: onAC80, thermalState: .serious, preferences: prefs),
                .none,
                "thermalGuard .serious defaults to .none"
            )
            expectEqual(
                SafetyEvaluator.evaluate(
                    battery: onAC80,
                    thermalState: .serious,
                    preferences: prefs,
                    treatSeriousThermalAsViolation: true
                ),
                .violation(.thermalOverheat),
                "thermalGuard .serious triggers .thermalOverheat when treatSeriousThermalAsViolation == true"
            )

            prefs.thermalGuardEnabled = false
            expectEqual(
                SafetyEvaluator.evaluate(
                    battery: onAC80,
                    thermalState: .critical,
                    preferences: prefs,
                    treatSeriousThermalAsViolation: true
                ),
                .none,
                "disabled thermalGuard ignores .critical"
            )
        }
    }

    // MARK: - AppFreezer Pure Helpers

    private static func testAppFreezerPureHelpers() {
        // Audio filter mode checks
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.app.a",
                appName: "App A",
                mode: .allowAllExceptBlocked,
                blockedApps: ["com.app.a"],
                allowedApps: []
            ),
            false,
            "allowAllExceptBlocked blocks com.app.a"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.app.b",
                appName: "App B",
                mode: .allowAllExceptBlocked,
                blockedApps: ["com.app.a"],
                allowedApps: []
            ),
            true,
            "allowAllExceptBlocked allows com.app.b"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.app.a",
                appName: "App A",
                mode: .allowAllExceptBlocked,
                blockedApps: ["com.app.a", "com.app.b"],
                allowedApps: []
            ),
            false,
            "allowAllExceptBlocked with all running apps blocked still blocks A"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.app.b",
                appName: "App B",
                mode: .allowAllExceptBlocked,
                blockedApps: ["com.app.a", "com.app.b"],
                allowedApps: []
            ),
            false,
            "allowAllExceptBlocked with all running apps blocked still blocks B"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.app.a",
                appName: "App A",
                mode: .allowOnlySelected,
                blockedApps: [],
                allowedApps: []
            ),
            false,
            "allowOnlySelected with empty allowedApps blocks com.app.a"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: nil,
                appName: "Unnamed",
                mode: .allowOnlySelected,
                blockedApps: [],
                allowedApps: []
            ),
            false,
            "allowOnlySelected with empty allowedApps blocks nil bundleID"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.spotify.client",
                appName: "Spotify",
                mode: .allowOnlySelected,
                blockedApps: [],
                allowedApps: ["com.spotify.client"]
            ),
            true,
            "allowOnlySelected allows selected bundleID"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.apple.Safari",
                appName: "Safari",
                mode: .allowOnlySelected,
                blockedApps: [],
                allowedApps: ["com.spotify.client", "com.apple.Safari"]
            ),
            true,
            "allowOnlySelected allows Safari alongside Spotify"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.apple.Safari",
                appName: "Safari",
                mode: .allowAllExceptBlocked,
                blockedApps: ["com.apple.Safari"],
                allowedApps: []
            ),
            false,
            "allowAllExceptBlocked blocks Safari when listed in blockedApps"
        )
        expectEqual(
            AppFreezer.isAudioAllowed(
                bundleID: "com.spotify.client",
                appName: "Spotify",
                mode: .allowAllExceptBlocked,
                blockedApps: ["com.apple.Safari"],
                allowedApps: []
            ),
            true,
            "allowAllExceptBlocked allows Spotify when only Safari is blocked"
        )

        // System executable path protection checks (including Cryptex prefixes)
        expectEqual(
            AppFreezer.normalizeExecutablePath("/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"),
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            "normalizeExecutablePath strips Preboot Cryptex OS prefix"
        )
        expectEqual(
            AppFreezer.normalizeExecutablePath("/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"),
            "/System/Applications/Safari.app/Contents/MacOS/Safari",
            "normalizeExecutablePath strips System Cryptex App prefix"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/usr/sbin/coreaudiod"),
            true,
            "protects /usr/sbin/coreaudiod"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/usr/libexec/bluetoothd"),
            true,
            "protects /usr/libexec/bluetoothd"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            true,
            "protects /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"),
            true,
            "protects Cryptex OS /System/Library WebKit.GPU XPC"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Volumes/Preboot/Cryptexes/Incoming/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            true,
            "protects Cryptex Incoming/OS /System/Library WebKit.WebContent XPC"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Cryptexes/App/usr/libexec/trustd"),
            true,
            "protects Cryptex App /usr/libexec path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Cryptexes/OS/usr/libexec/somehelper"),
            true,
            "protects Cryptex OS /usr/libexec path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"),
            false,
            "does not treat Cryptex Safari.app as protected system daemon path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"),
            false,
            "does not treat Preboot Cryptex Safari.app as protected system daemon path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/Applications/Safari.app/Contents/MacOS/Safari"),
            false,
            "does not treat /Applications/Safari.app as protected system daemon path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Applications/Music.app/Contents/MacOS/Music"),
            false,
            "does not treat /System/Applications/Music.app as protected system daemon path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/bin/zsh"),
            true,
            "protects core /bin shell commands from freezing"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect"),
            true,
            "protects /Library/Apple system components from freezing"
        )

        // Core protected bundle identifier checks
        expect(
            !AppFreezer.shared.systemProtectedIdentifiers.contains("com.google.antigravity-ide"),
            "user IDE apps such as Antigravity IDE are shown in app lists and user-configurable"
        )
        expect(
            AppFreezer.shared.isProtectedSystemBundleIdentifier("com.apple.SecurityAgent"),
            "protects core macOS SecurityAgent"
        )
        expect(
            AppFreezer.shared.isProtectedSystemBundleIdentifier("com.apple.UserNotificationCenter"),
            "protects core macOS UserNotificationCenter"
        )
        expect(
            AppFreezer.shared.isProtectedSystemBundleIdentifier("com.apple.security.KeychainCircleNotification"),
            "protects com.apple.security.* system components"
        )

        // Pure freeze policy checks
        expectEqual(
            AppFreezer.shouldFreezeApp(
                bundleID: "com.apple.Safari",
                appName: "Safari",
                executablePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
                systemProtectedIdentifiers: ["com.apple.finder"],
                whitelist: [],
                keepAudio: true,
                isProducingAudio: true,
                audioMode: .allowOnlySelected,
                blockedAudioApps: [],
                allowedAudioApps: ["com.apple.Safari", "com.spotify.client"]
            ),
            false,
            "shouldFreezeApp keeps Cryptex Safari alive when playing allowed audio"
        )
        expectEqual(
            AppFreezer.shouldFreezeApp(
                bundleID: "com.apple.Safari",
                appName: "Safari",
                executablePath: "/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
                systemProtectedIdentifiers: ["com.apple.finder"],
                whitelist: [],
                keepAudio: true,
                isProducingAudio: false,
                audioMode: .allowOnlySelected,
                blockedAudioApps: [],
                allowedAudioApps: ["com.apple.Safari"]
            ),
            true,
            "shouldFreezeApp freezes idle non-whitelisted Safari when not playing audio"
        )
        expectEqual(
            AppFreezer.shouldFreezeApp(
                bundleID: "com.apple.dock",
                appName: "Dock",
                executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                systemProtectedIdentifiers: AppFreezer.shared.systemProtectedIdentifiers,
                whitelist: [],
                keepAudio: false,
                isProducingAudio: false,
                audioMode: .allowAllExceptBlocked,
                blockedAudioApps: [],
                allowedAudioApps: []
            ),
            false,
            "shouldFreezeApp never freezes systemProtectedIdentifiers"
        )
        expectEqual(
            AppFreezer.shouldFreezeApp(
                bundleID: "com.google.antigravity-ide",
                appName: "Antigravity IDE",
                executablePath: "/Applications/Antigravity.app/Contents/MacOS/Electron",
                systemProtectedIdentifiers: AppFreezer.shared.systemProtectedIdentifiers,
                whitelist: [],
                keepAudio: false,
                isProducingAudio: false,
                audioMode: .allowAllExceptBlocked,
                blockedAudioApps: [],
                allowedAudioApps: []
            ),
            true,
            "shouldFreezeApp freezes non-whitelisted user apps like Antigravity IDE unless whitelisted"
        )
        expectEqual(
            AppFreezer.shouldFreezeApp(
                bundleID: "com.apple.Terminal",
                appName: "Terminal",
                executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                systemProtectedIdentifiers: [],
                whitelist: ["com.apple.Terminal"],
                keepAudio: false,
                isProducingAudio: false,
                audioMode: .allowAllExceptBlocked,
                blockedAudioApps: [],
                allowedAudioApps: []
            ),
            false,
            "shouldFreezeApp never freezes whitelisted apps"
        )

        // PID reuse & stopped status resume checks
        let record = FrozenProcessRecord(pid: 4321, startSec: 1_700_000_100, startUsec: 555_000)
        expectEqual(
            AppFreezer.shouldResumeProcess(
                record: record,
                liveStartSec: 1_700_000_100,
                liveStartUsec: 555_000,
                isStopped: true
            ),
            true,
            "shouldResumeProcess returns true when startSec, startUsec match and isStopped == true"
        )
        expectEqual(
            AppFreezer.shouldResumeProcess(
                record: record,
                liveStartSec: 1_700_000_101,
                liveStartUsec: 555_000,
                isStopped: true
            ),
            false,
            "shouldResumeProcess returns false on startSec mismatch (PID reuse)"
        )
        expectEqual(
            AppFreezer.shouldResumeProcess(
                record: record,
                liveStartSec: 1_700_000_100,
                liveStartUsec: 555_001,
                isStopped: true
            ),
            false,
            "shouldResumeProcess returns false on startUsec mismatch (PID reuse)"
        )
        expectEqual(
            AppFreezer.shouldResumeProcess(
                record: record,
                liveStartSec: 1_700_000_100,
                liveStartUsec: 555_000,
                isStopped: false
            ),
            false,
            "shouldResumeProcess returns false when process is not stopped"
        )
    }

    // MARK: - SudoersPolicy & PrivilegedCommandResult

    private static func testSudoersPolicyAndPrivilegedResult() {
        expectEqual(
            SudoersPolicy.ghostModeRulePath,
            "/private/etc/sudoers.d/ghostmode",
            "ghostModeRulePath matches expected sudoers path"
        )
        expectEqual(
            SudoersPolicy.managedRulePaths,
            ["/private/etc/sudoers.d/ghostmode"],
            "managedRulePaths includes ghostmode sudoers rule"
        )

        expectEqual(AppMetadata.name, "Ghost Mode", "AppMetadata.name is Ghost Mode")
        expectEqual(AppMetadata.version, "2.1", "AppMetadata.version matches current release")
        let defaultRevoke = SudoersPolicy.revokeCommand()
        expectEqual(
            defaultRevoke,
            "/bin/rm -f /private/etc/sudoers.d/ghostmode",
            "default revokeCommand removes ghostmode sudoers file"
        )
        expect(
            defaultRevoke.contains("/private/etc/sudoers.d/ghostmode"),
            "default revokeCommand references ghostmode rule path"
        )

        expectEqual(
            SudoersPolicy.revokeCommand(paths: ["/tmp/custom path", "/tmp/it's_a_test"]),
            "/bin/rm -f '/tmp/custom path' '/tmp/it'\\''s_a_test'",
            "revokeCommand quotes spaces and escapes single quotes safely"
        )
        expectEqual(
            SudoersPolicy.revokeCommand(paths: []),
            "/bin/rm -f",
            "revokeCommand handles empty path list cleanly"
        )

        let successResult = PrivilegedCommandResult(success: true, cancelled: false, errorMessage: nil)
        let cancelledResult = PrivilegedCommandResult(success: false, cancelled: true, errorMessage: nil)
        let failedResult = PrivilegedCommandResult(success: false, cancelled: false, errorMessage: "Auth failed")

        expectEqual(successResult.success, true, "success result marks success == true")
        expectEqual(successResult.cancelled, false, "success result marks cancelled == false")
        expectNil(successResult.errorMessage, "success result has nil errorMessage")

        expectEqual(cancelledResult.success, false, "cancelled result marks success == false")
        expectEqual(cancelledResult.cancelled, true, "cancelled result marks cancelled == true")
        expectNil(cancelledResult.errorMessage, "cancelled result has nil errorMessage")

        expectEqual(failedResult.success, false, "failed result marks success == false")
        expectEqual(failedResult.cancelled, false, "failed result marks cancelled == false")
        expectEqual(failedResult.errorMessage, "Auth failed", "failed result preserves errorMessage")
        expect(successResult != failedResult, "PrivilegedCommandResult Equatable distinguishes results")
        expectEqual(
            failedResult,
            PrivilegedCommandResult(success: false, cancelled: false, errorMessage: "Auth failed"),
            "PrivilegedCommandResult Equatable matches identical values"
        )

        // Hardened username & command builder security checks
        expectEqual(SudoersPolicy.validatedUsername("arpit"), "arpit", "validates normal username")
        expectEqual(SudoersPolicy.validatedUsername("first.last_2-a"), "first.last_2-a", "validates safe punctuation username")
        expectNil(SudoersPolicy.validatedUsername(""), "rejects empty username")
        expectNil(SudoersPolicy.validatedUsername("root"), "rejects root")
        expectNil(SudoersPolicy.validatedUsername("loginwindow"), "rejects loginwindow")
        expectNil(SudoersPolicy.validatedUsername("_mbsetupuser"), "rejects _mbsetupuser")
        expectNil(SudoersPolicy.validatedUsername("-evil"), "rejects leading hyphen")
        expectNil(SudoersPolicy.validatedUsername(".evil"), "rejects leading dot")
        expectNil(SudoersPolicy.validatedUsername("arpit;rm -rf /"), "rejects shell metacharacters")
        expectNil(SudoersPolicy.validatedUsername("arpit$(id)"), "rejects command substitution")
        expectNil(SudoersPolicy.validatedUsername(String(repeating: "a", count: 65)), "rejects >64 char username")

        let installCmd = SudoersPolicy.installCommand(forUsername: "arpit") ?? ""
        expect(!installCmd.isEmpty, "installCommand builds command for valid username")
        expect(installCmd.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "installCommand locks down PATH")
        expect(installCmd.contains("/usr/bin/mktemp -d /private/etc/sudoers.d/.ghostmode."), "installCommand stages inside root-owned sudoers.d")
        expect(installCmd.contains("/usr/sbin/visudo -cf"), "installCommand validates with absolute visudo")
        expect(installCmd.contains("[ ! -L /private/etc/sudoers.d ]"), "installCommand rejects sudoers.d symlink")
        expect(installCmd.contains("GHOSTMODE_PMSET = /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -g"), "installCommand enforces exact least-privilege pmset rules")
        expectNil(SudoersPolicy.installCommand(forUsername: "arpit;id"), "installCommand rejects injection username")

        let hardenedRevoke = SudoersPolicy.hardenedRevokeCommand()
        expect(hardenedRevoke.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "hardenedRevokeCommand locks down PATH")
        expect(hardenedRevoke.contains("[ ! -L /private/etc/sudoers.d ]"), "hardenedRevokeCommand rejects sudoers.d symlink")
        expect(hardenedRevoke.contains("/bin/rm -f /private/etc/sudoers.d/ghostmode"), "hardenedRevokeCommand removes ghostmode rule file")

        expectEqual(
            PrivilegedAction.setLidSleepDisabled(true).resolvedCommand(),
            "/usr/bin/pmset disablesleep 1",
            "PrivilegedAction.setLidSleepDisabled(true) resolves exact pmset command"
        )
        expectEqual(
            PrivilegedAction.setLidSleepDisabled(false).resolvedCommand(),
            "/usr/bin/pmset disablesleep 0",
            "PrivilegedAction.setLidSleepDisabled(false) resolves exact pmset command"
        )
        expectEqual(
            PrivilegedAction.revokePasswordlessSudo.resolvedCommand(),
            hardenedRevoke,
            "PrivilegedAction.revokePasswordlessSudo resolves hardened revoke command"
        )
        expectNil(
            PrivilegedAction.configurePasswordlessSudo(username: "bad user").resolvedCommand(),
            "PrivilegedAction.configurePasswordlessSudo rejects invalid username"
        )
    }

    // MARK: - SudoFeatureAvailability

    private static func testSudoFeatureAvailability() {
        let summary = SudoFeatureAvailability.lackingFeaturesSummary()
        expect(!summary.isEmpty, "lackingFeaturesSummary is non-empty")
        expect(summary.contains("Screen Off"), "lackingFeaturesSummary mentions Screen Off")
        expect(summary.contains("App Freeze"), "lackingFeaturesSummary mentions App Freeze")
        expect(summary.contains("prompts"), "lackingFeaturesSummary mentions start/stop prompts")

        expectEqual(
            SudoFeatureAvailability.effectiveLidFeatureToggle(storedValue: true, sudoConfigured: false),
            false,
            "effectiveLidFeatureToggle returns false when sudo is not configured even if storedValue is true"
        )
        expectEqual(
            SudoFeatureAvailability.effectiveLidFeatureToggle(storedValue: false, sudoConfigured: false),
            false,
            "effectiveLidFeatureToggle returns false when sudo is not configured and storedValue is false"
        )
        expectEqual(
            SudoFeatureAvailability.effectiveLidFeatureToggle(storedValue: true, sudoConfigured: true),
            true,
            "effectiveLidFeatureToggle preserves storedValue true when sudo is configured"
        )
        expectEqual(
            SudoFeatureAvailability.effectiveLidFeatureToggle(storedValue: false, sudoConfigured: true),
            false,
            "effectiveLidFeatureToggle preserves storedValue false when sudo is configured"
        )
    }
}
