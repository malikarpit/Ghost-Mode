//
//  PowerManager.swift
//  Ghost Mode
//

import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Security

// MARK: - Power Manager

public final class PowerManager {
    public static let shared = PowerManager()

    private var powerAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var processActivity: NSObjectProtocol?
    private var _cachedSudoConfigured: Bool?

    private init() {}

    // MARK: - Shell & Process Execution

    public func shell(_ command: String) -> (output: String, exitCode: Int32) {
        return runProcess("/bin/sh", arguments: ["-c", command])
    }

    private func runProcess(_ executablePath: String, arguments: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
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

    // MARK: - pmset & Sudo Management

    public func checkLidSleepDisabled() -> Bool {
        let (output, _) = runProcess("/usr/bin/pmset", arguments: ["-g"])
        return output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    public func isPasswordlessSudoConfigured(forceRefresh: Bool = false) -> Bool {
        if !forceRefresh, let cached = _cachedSudoConfigured {
            return cached
        }
        let (_, exitCode) = runProcess("/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "-g"])
        let result = (exitCode == 0)
        _cachedSudoConfigured = result
        return result
    }

    public func invalidateSudoCache() {
        _cachedSudoConfigured = nil
    }

    public static func currentVerifiedUsername() -> String? {
        guard let pw = getpwuid(getuid()), let cName = pw.pointee.pw_name else {
            return nil
        }
        return SudoersPolicy.validatedUsername(String(cString: cName))
    }

    public func verifyBundleCodeSignature() -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let runningCode = selfCode else {
            return false
        }

        // Note: dynamic SecCode does not accept kSecCSCheckAllArchitectures; strict disk check validates all slices below.
        guard SecCodeCheckValidity(runningCode, [], nil) == errSecSuccess else {
            return false
        }

        var runningStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, [], &runningStatic) == errSecSuccess,
              let selfStaticCode = runningStatic else {
            return false
        }

        var selfInfoRef: CFDictionary?
        guard SecCodeCopySigningInformation(selfStaticCode, [], &selfInfoRef) == errSecSuccess,
              let selfInfo = selfInfoRef as? [String: Any],
              (selfInfo[kSecCodeInfoIdentifier as String] as? String) == AppMetadata.bundleIdentifier else {
            return false
        }

        var diskStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &diskStatic) == errSecSuccess,
              let diskCode = diskStatic else {
            return false
        }

        let staticFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(diskCode, staticFlags, nil) == errSecSuccess else {
            return false
        }

        var diskInfoRef: CFDictionary?
        guard SecCodeCopySigningInformation(diskCode, [], &diskInfoRef) == errSecSuccess,
              let diskInfo = diskInfoRef as? [String: Any],
              (diskInfo[kSecCodeInfoIdentifier as String] as? String) == AppMetadata.bundleIdentifier else {
            return false
        }

        return true
    }

    public func performPrivilegedAction(_ action: PrivilegedAction) -> PrivilegedCommandResult {
        guard verifyBundleCodeSignature() else {
            return PrivilegedCommandResult(
                success: false,
                cancelled: false,
                errorMessage: "Security verification failed: Ghost Mode bundle signature was modified on disk."
            )
        }
        guard let command = action.resolvedCommand() else {
            return PrivilegedCommandResult(
                success: false,
                cancelled: false,
                errorMessage: "Invalid privileged action parameters."
            )
        }
        return executePrivilegedAppleScript(command: command)
    }

    private func executePrivilegedAppleScript(command: String) -> PrivilegedCommandResult {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "do shell script \"\(escapedCommand)\" with administrator privileges"
        guard let script = NSAppleScript(source: scriptSource) else {
            return PrivilegedCommandResult(
                success: false,
                cancelled: false,
                errorMessage: "Unable to initialize AppleScript."
            )
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                return PrivilegedCommandResult(success: false, cancelled: true, errorMessage: nil)
            }
            let message = (error[NSAppleScript.errorBriefMessage] as? String)
                ?? (error[NSAppleScript.errorMessage] as? String)
            return PrivilegedCommandResult(success: false, cancelled: false, errorMessage: message)
        }
        return PrivilegedCommandResult(success: true, cancelled: false, errorMessage: nil)
    }

    public func setLidSleep(
        disabled: Bool,
        allowInteractivePrompt: Bool = true,
        preventDisplaySleep: Bool = false
    ) -> Bool {
        let value = disabled ? "1" : "0"
        var success = false

        if isPasswordlessSudoConfigured() {
            let (_, exitCode) = runProcess("/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "disablesleep", value])
            if exitCode == 0 {
                success = true
            } else {
                invalidateSudoCache()
                _cachedSudoConfigured = false
            }
        }

        if !success && allowInteractivePrompt {
            success = performPrivilegedAction(.setLidSleepDisabled(disabled)).success
        }

        if disabled {
            if success {
                startNativePowerAssertion(preventDisplaySleep: preventDisplaySleep)
            }
        } else {
            // ALWAYS release native power assertion and App Nap activity when disabling keep-awake,
            // even if pmset fails or interactive prompting is suppressed behind a closed lid.
            stopNativePowerAssertion()
        }

        return success
    }

    // MARK: - Native IOKit Power Assertion & App Nap Prevention

    public func startNativePowerAssertion(preventDisplaySleep: Bool = false) {
        let reason = "Ghost Mode Keep-Awake Session (by \(AppMetadata.author))"

        if powerAssertionID == 0 {
            var newID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithDescription(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                "\(AppMetadata.bundleIdentifier).keepAwake" as CFString,
                "Ghost Mode active keep-awake session" as CFString,
                reason as CFString,
                nil,
                0,
                nil,
                &newID
            )
            if status == kIOReturnSuccess {
                powerAssertionID = newID
            }
        }

        if preventDisplaySleep {
            if displayAssertionID == 0 {
                var newDisplayID: IOPMAssertionID = 0
                let status = IOPMAssertionCreateWithDescription(
                    kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                    "\(AppMetadata.bundleIdentifier).keepDisplayAwake" as CFString,
                    "Ghost Mode active keep-display-awake assertion" as CFString,
                    reason as CFString,
                    nil,
                    0,
                    nil,
                    &newDisplayID
                )
                if status == kIOReturnSuccess {
                    displayAssertionID = newDisplayID
                }
            }
        } else if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }

        if processActivity == nil {
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: reason
            )
        }
    }

    public func stopNativePowerAssertion() {
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        if let activity = processActivity {
            ProcessInfo.processInfo.endActivity(activity)
            processActivity = nil
        }
    }

    public func hasActivePowerAssertion() -> Bool {
        return powerAssertionID != 0 && processActivity != nil
    }

    public func currentPowerAssertionSummary() -> String {
        var parts: [String] = []
        if powerAssertionID != 0 {
            parts.append("SystemSleep(id=\(powerAssertionID))")
        }
        if displayAssertionID != 0 {
            parts.append("DisplaySleep(id=\(displayAssertionID))")
        }
        if processActivity != nil {
            parts.append("AppNapDisabled")
        }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    public func verifyAndRepairActivePowerState(preventDisplaySleep: Bool = false) {
        let needsDisplayRepair = preventDisplaySleep ? (displayAssertionID == 0) : (displayAssertionID != 0)
        if !hasActivePowerAssertion() || needsDisplayRepair {
            startNativePowerAssertion(preventDisplaySleep: preventDisplaySleep)
        }
        if !checkLidSleepDisabled() && isPasswordlessSudoConfigured(forceRefresh: true) {
            let (_, exitCode) = runProcess("/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "disablesleep", "1"])
            if exitCode != 0 {
                invalidateSudoCache()
            }
        }
    }

    // MARK: - Battery Status

    public func getBatteryStatus() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        let providingPowerSource = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as? String
        var descriptions: [[String: Any]] = []
        descriptions.reserveCapacity(sources.count)

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                descriptions.append(desc)
            }
        }

        return PowerSnapshotParser.parseBatteryStatus(
            sources: descriptions,
            providingPowerSource: providingPowerSource
        )
    }
}
