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

        // 2. Legacy empty audioAppWhitelist migration -> .allowAllExceptBlocked
        do {
            let suiteName = "com.arpit.GhostMode.tests.migrateEmpty.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            defaults.set([String](), forKey: Preferences.Keys.legacyAudioAppWhitelist)
            let prefs = Preferences(defaults: defaults)
            expectEqual(prefs.audioFilterMode, .allowAllExceptBlocked, "empty legacy whitelist migrates to allowAllExceptBlocked")
            expectEqual(prefs.audioAllowedApps, [], "empty legacy whitelist keeps audioAllowedApps empty")
            expectEqual(defaults.bool(forKey: Preferences.Keys.didMigrateAudioWhitelistV2), true, "migration flag set for empty")
        }

        // 3. Legacy non-empty audioAppWhitelist migration -> .allowOnlySelected + audioAllowedApps
        do {
            let suiteName = "com.arpit.GhostMode.tests.migrateSelected.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            defaults.set(["com.spotify.client"], forKey: Preferences.Keys.legacyAudioAppWhitelist)
            let prefs = Preferences(defaults: defaults)
            expectEqual(prefs.audioFilterMode, .allowOnlySelected, "non-empty legacy whitelist migrates to allowOnlySelected")
            expectEqual(prefs.audioAllowedApps, ["com.spotify.client"], "non-empty legacy whitelist migrates bundle IDs")
            expectEqual(defaults.bool(forKey: Preferences.Keys.didMigrateAudioWhitelistV2), true, "migration flag set for non-empty")
        }

        // 4. didChangeNotification fires AFTER defaults reflects the new value
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

        // System executable path protection checks
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
            AppFreezer.isProtectedSystemExecutablePath("/Applications/Safari.app/Contents/MacOS/Safari"),
            false,
            "does not treat /Applications/Safari.app as protected system daemon path"
        )
        expectEqual(
            AppFreezer.isProtectedSystemExecutablePath("/System/Applications/Music.app/Contents/MacOS/Music"),
            false,
            "does not treat /System/Applications/Music.app as protected system daemon path"
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
}
