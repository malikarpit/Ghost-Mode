//
//  SafetyControllers.swift
//  Ghost Mode
//

import Foundation
import IOKit.ps

// MARK: - Internal Battery Snapshot Parser

public struct PowerSnapshotParser {
    /// Parses IOKit power source dictionaries, strictly filtering for the Mac's internal battery
    /// (`kIOPSTypeKey == kIOPSInternalBatteryType` and `kIOPSIsPresentKey != false`).
    /// Falls back to `providingPowerSource == kIOPSACPowerValue` when the battery dictionary lacks a state string.
    public static func parseBatteryStatus(sources: [[String: Any]], providingPowerSource: String?) -> BatteryStatus? {
        let providingAC = (providingPowerSource == (kIOPSACPowerValue as String))

        for desc in sources {
            guard (desc[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else {
                continue
            }
            if let isPresent = desc[kIOPSIsPresentKey as String] as? Bool, !isPresent {
                continue
            }

            let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maxCapacity = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false

            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            let isAC: Bool
            if let state = state, !state.isEmpty {
                isAC = (state == (kIOPSACPowerValue as String))
            } else {
                isAC = providingAC
            }

            let rawPercent = maxCapacity > 0 ? (current * 100) / maxCapacity : current
            let percent = min(100, max(0, rawPercent))
            let timeKey: String? = isCharging
                ? (kIOPSTimeToFullChargeKey as String)
                : (!isAC ? (kIOPSTimeToEmptyKey as String) : nil)
            let rawTime = timeKey.flatMap { desc[$0] as? Int }
            let timeRemainingMinutes = rawTime.flatMap { ($0 > 0 && $0 <= 2400) ? $0 : nil }
            return BatteryStatus(
                percent: percent,
                isCharging: isCharging,
                isAC: isAC,
                timeRemainingMinutes: timeRemainingMinutes
            )
        }

        return nil
    }
}

// MARK: - Unified Safety Policy Evaluator

public enum SafetyEvaluator {
    public static func evaluate(
        battery: BatteryStatus?,
        thermalState: ProcessInfo.ThermalState,
        preferences: Preferences,
        treatSeriousThermalAsViolation: Bool = false
    ) -> SafetyViolation {
        if preferences.acOnlyModeEnabled, let battery = battery, !battery.isAC {
            return .violation(.unpluggedAC)
        }

        if preferences.batteryCutoffEnabled,
           let battery = battery,
           !battery.isAC,
           battery.percent <= preferences.batteryCutoffThreshold {
            return .violation(.lowBattery(percent: battery.percent))
        }

        if preferences.thermalGuardEnabled &&
            (thermalState == .critical || (treatSeriousThermalAsViolation && thermalState == .serious)) {
            return .violation(.thermalOverheat)
        }

        return .none
    }
}

// MARK: - Power Transition Debouncer (USB-C PD Glitch Protection)

public final class PowerTransitionDebouncer {
    private let acDisconnectDelay: TimeInterval = 4.0
    private let lowBatteryDelay: TimeInterval = 3.0

    private var acDisconnectWorkItem: DispatchWorkItem?
    private var lowBatteryWorkItem: DispatchWorkItem?

    public init() {}

    public func evaluate(
        battery: BatteryStatus?,
        isActive: Bool,
        acOnlyEnabled: Bool,
        batteryCutoffEnabled: Bool,
        cutoffThreshold: Int,
        readLatestBattery: @escaping () -> BatteryStatus?,
        onStop: @escaping (SessionStopReason) -> Void
    ) {
        guard isActive, let battery = battery else {
            cancelAll()
            return
        }

        if battery.isAC {
            cancelAll()
            return
        }

        if acOnlyEnabled {
            if acDisconnectWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.acDisconnectWorkItem = nil
                    guard let latest = readLatestBattery(), !latest.isAC else { return }
                    self.lowBatteryWorkItem?.cancel()
                    self.lowBatteryWorkItem = nil
                    onStop(.unpluggedAC)
                }
                acDisconnectWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + acDisconnectDelay, execute: item)
            }
        } else {
            acDisconnectWorkItem?.cancel()
            acDisconnectWorkItem = nil
        }

        if batteryCutoffEnabled && battery.percent <= cutoffThreshold {
            if lowBatteryWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.lowBatteryWorkItem = nil
                    guard let latest = readLatestBattery(),
                          !latest.isAC,
                          latest.percent <= cutoffThreshold else { return }
                    self.acDisconnectWorkItem?.cancel()
                    self.acDisconnectWorkItem = nil
                    onStop(.lowBattery(percent: latest.percent))
                }
                lowBatteryWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + lowBatteryDelay, execute: item)
            }
        } else {
            lowBatteryWorkItem?.cancel()
            lowBatteryWorkItem = nil
        }
    }

    public func cancelAll() {
        acDisconnectWorkItem?.cancel()
        acDisconnectWorkItem = nil
        lowBatteryWorkItem?.cancel()
        lowBatteryWorkItem = nil
    }
}

// MARK: - Two-Tier Thermal Guard Controller

public final class ThermalGuardController {
    private let seriousWarningCooldown: TimeInterval = 300.0
    private let recoveryResetDelay: TimeInterval = 20.0
    private let seriousGraceDuration: TimeInterval = 90.0
    private let criticalConfirmDuration: TimeInterval = 4.0

    private var seriousGraceWorkItem: DispatchWorkItem?
    private var criticalConfirmWorkItem: DispatchWorkItem?
    private var recoveryResetWorkItem: DispatchWorkItem?
    private var hasWarnedSerious = false
    private var lastWarningDate: Date = .distantPast
    private var isStoppingForThermal = false

    public init() {}

    public func evaluate(
        state: ProcessInfo.ThermalState,
        isActive: Bool,
        guardEnabled: Bool,
        onWarnSerious: @escaping () -> Void,
        onCutoff: @escaping () -> Void
    ) {
        guard isActive && guardEnabled && !isStoppingForThermal else {
            resetTimers()
            return
        }

        switch state {
        case .nominal, .fair:
            seriousGraceWorkItem?.cancel()
            seriousGraceWorkItem = nil
            criticalConfirmWorkItem?.cancel()
            criticalConfirmWorkItem = nil

            if hasWarnedSerious && recoveryResetWorkItem == nil {
                let reset = DispatchWorkItem { [weak self] in
                    self?.hasWarnedSerious = false
                    self?.recoveryResetWorkItem = nil
                }
                recoveryResetWorkItem = reset
                DispatchQueue.main.asyncAfter(deadline: .now() + recoveryResetDelay, execute: reset)
            }

        case .serious:
            recoveryResetWorkItem?.cancel()
            recoveryResetWorkItem = nil
            criticalConfirmWorkItem?.cancel()
            criticalConfirmWorkItem = nil

            let now = Date()
            if !hasWarnedSerious && now.timeIntervalSince(lastWarningDate) >= seriousWarningCooldown {
                hasWarnedSerious = true
                lastWarningDate = now
                onWarnSerious()
            }

            if seriousGraceWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.isStoppingForThermal else { return }
                    self.seriousGraceWorkItem = nil
                    let live = ProcessInfo.processInfo.thermalState
                    guard live == .serious || live == .critical else { return }
                    self.isStoppingForThermal = true
                    onCutoff()
                }
                seriousGraceWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + seriousGraceDuration, execute: item)
            }

        case .critical:
            recoveryResetWorkItem?.cancel()
            recoveryResetWorkItem = nil
            seriousGraceWorkItem?.cancel()
            seriousGraceWorkItem = nil

            if criticalConfirmWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.isStoppingForThermal else { return }
                    self.criticalConfirmWorkItem = nil
                    guard ProcessInfo.processInfo.thermalState == .critical else { return }
                    self.isStoppingForThermal = true
                    onCutoff()
                }
                criticalConfirmWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + criticalConfirmDuration, execute: item)
            }

        @unknown default:
            break
        }
    }

    public func resetForNewSession() {
        resetTimers()
        hasWarnedSerious = false
        isStoppingForThermal = false
    }

    private func resetTimers() {
        seriousGraceWorkItem?.cancel()
        seriousGraceWorkItem = nil
        criticalConfirmWorkItem?.cancel()
        criticalConfirmWorkItem = nil
        recoveryResetWorkItem?.cancel()
        recoveryResetWorkItem = nil
    }
}
