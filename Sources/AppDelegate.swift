//
//  AppDelegate.swift
//  Ghost Mode
//

import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = GhostModeViewModel()
    private var statusBarController: StatusBarController!

    private let powerDebouncer = PowerTransitionDebouncer()
    private let thermalGuard = ThermalGuardController()
    private let signalManager = SignalManager()
    private let systemPowerMonitor = SystemPowerSleepMonitor()

    private var sessionExpirationTimer: Timer?
    private var countdownBadgeTimer: Timer?
    private var driftVerificationTimer: Timer?
    private var closedLidReconcileTimer: Timer?
    private var popoverRefreshTimer: Timer?

    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var iokitNotifyPort: IONotificationPortRef?
    private var iokitNotification: io_object_t = 0
    private var iokitRootDomain: io_service_t = 0

    private var lastLidClosedState: Bool = false
    private var didPromptPendingRestoreForCurrentOpen: Bool = false
    private var isTerminating = false
    private var isPrivilegedActionInFlight = false

    private var popoverRefreshGeneration: UInt64 = 0
    private var isPopoverRefreshInFlight = false
    private var pendingForcedSudoRefresh = false
    private var auxRefreshGeneration: UInt64 = 0
    private var telemetryFollowupWorkItem: DispatchWorkItem?

    private enum ReconcileTrigger {
        case launchAdoption
        case startSession
        case extendSession
        case powerSourceChanged
        case thermalStateChanged
        case lidStateChanged
        case safetyPreferenceChanged
        case freezePreferenceChanged
        case driftCheck
        case systemDidWake
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Ghost Mode v\(AppMetadata.version) by \(AppMetadata.author): Initialized successfully.")

        AppNotificationService.shared.configure()
        AppNotificationService.shared.onNotificationActivated = { [weak self] in
            self?.statusBarController.showPopover()
        }

        NSApp.setActivationPolicy(Preferences.shared.showInDock ? .regular : .accessory)

        // Recover any processes left SIGSTOPped by a prior crash or SIGKILL
        AppFreezer.shared.recoverOrphanedFrozenApps()

        signalManager.install { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleGracefulSignalExit()
            }
        }

        wireViewModelCallbacks()
        viewModel.ghostMemMB = ProcessDiagnostics.getMemoryFootprintMB()
        _ = ProcessDiagnostics.warmUpCPUBaselineIfStale(maxAgeSeconds: 0)

        statusBarController = StatusBarController(
            viewModel: viewModel,
            onWillOpen: { [weak self] in
                _ = ProcessDiagnostics.warmUpCPUBaselineIfStale(maxAgeSeconds: 8.0)
                self?.refreshPopoverData(includeAuxiliary: true)
            },
            onPopoverVisibilityChanged: { [weak self] isVisible in
                if isVisible {
                    self?.startPopoverRefreshTimer()
                } else {
                    self?.stopPopoverRefreshTimer()
                }
            }
        )

        lastLidClosedState = DisplayManager.shared.isLidClosed()
        setupEventMonitoring()

        let showMenuName = Notification.Name("com.arpit.ghostmode.showMenu")
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(didReceiveShowMenuNotification(_:)),
            name: showMenuName,
            object: nil
        )

        if PowerManager.shared.checkLidSleepDisabled() {
            viewModel.sessionMode = .activeIndefinite
            reconcile(trigger: .launchAdoption)
        } else {
            viewModel.sessionMode = .idle
            refreshPopoverData()
            if Preferences.shared.autoStartOnLaunch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.viewModel.sessionMode.isActive else { return }
                    self.startKeepAwakeSession(durationSeconds: Preferences.shared.defaultDuration)
                }
            }
        }

        if !Preferences.shared.hasSeenWelcome {
            Preferences.shared.hasSeenWelcome = true
            AppNotificationService.shared.requestAuthorizationIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppNotificationService.shared.send(
                    GhostNotificationFactory.welcome(),
                    playSound: Preferences.shared.soundNotificationsEnabled
                )
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController.showPopover()
        return true
    }

    @objc private func didReceiveShowMenuNotification(_ notification: Notification) {
        statusBarController.showPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isTerminating else { return }
        isTerminating = true
        performCleanupBeforeExit()
    }

    private func handleGracefulSignalExit() {
        guard !isTerminating else { return }
        isTerminating = true
        performCleanupBeforeExit()
        NSApplication.shared.terminate(nil)
    }

    private func performCleanupBeforeExit() {
        teardownEventMonitoring()
        systemPowerMonitor.stop()
        stopSessionTimers()
        stopPopoverRefreshTimer()
        powerDebouncer.cancelAll()
        AppFreezer.shared.unfreezeAllApps()
        PowerManager.shared.stopNativePowerAssertion()

        if PowerManager.shared.isPasswordlessSudoConfigured() {
            _ = PowerManager.shared.setLidSleep(disabled: false, allowInteractivePrompt: false)
        }

        if globalLockFileDescriptor >= 0 {
            flock(globalLockFileDescriptor, LOCK_UN)
            close(globalLockFileDescriptor)
            globalLockFileDescriptor = -1
        }
    }

    // MARK: - ViewModel Wiring

    private func wireViewModelCallbacks() {
        viewModel.onStartSession = { [weak self] seconds in
            self?.startKeepAwakeSession(durationSeconds: seconds)
        }
        viewModel.onStopSession = { [weak self] in
            self?.stopKeepAwakeSession(reason: .userManual)
        }
        viewModel.onExtendSession = { [weak self] seconds in
            self?.extendSession(by: seconds)
        }
        viewModel.onTurnOffScreen = { [weak self] in
            self?.statusBarController.closePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                DisplayManager.shared.turnOffDisplay(force: true)
            }
        }
        viewModel.onScreenSaver = { [weak self] in
            self?.statusBarController.closePopover()
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "ScreenSaverEngine"]
                try? process.run()
                process.waitUntilExit()
            }
        }
        viewModel.onUnfreezeAll = { [weak self] in
            self?.unfreezeAllNow()
        }
        viewModel.onCopyDiagnostics = { [weak self] in
            self?.copyDiagnostics()
        }
        viewModel.onResetDefaults = { [weak self] in
            self?.resetDefaults()
        }
        viewModel.onDisplayPreferenceChanged = { [weak self] in
            guard let self = self else { return }
            if self.viewModel.sessionMode.isActive {
                PowerManager.shared.startNativePowerAssertion(
                    preventDisplaySleep: Preferences.shared.preventDisplaySleep
                )
            }
            self.refreshPopoverData()
        }
        viewModel.onSafetyPreferenceChanged = { [weak self] in
            self?.reconcile(trigger: .safetyPreferenceChanged)
        }
        viewModel.onFreezePreferenceChanged = { [weak self] in
            self?.reconcile(trigger: .freezePreferenceChanged)
        }
        viewModel.onSetupOrRevokeSudo = { [weak self] in
            self?.handleSetupOrRevokeSudo()
        }
        viewModel.onToggleDock = { [weak self] in
            NSApp.setActivationPolicy(Preferences.shared.showInDock ? .regular : .accessory)
            self?.refreshPopoverData()
        }
        viewModel.onToggleLogin = { [weak self] in
            self?.handleToggleLogin()
        }
        viewModel.onToggleCountdown = { [weak self] in
            self?.handleToggleCountdown()
        }
        viewModel.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        viewModel.onFocusPopover = { [weak self] in
            self?.statusBarController.activateForTextInput()
        }
        viewModel.onSelectedTabChanged = { [weak self] tab in
            guard let self = self, tab == .prefs else { return }
            self.refreshPopoverData(forceSudoRefresh: true, includeAuxiliary: true)
        }
    }

    // MARK: - Event Monitoring

    private func setupEventMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 1. IOKit Power Sources Notification RunLoop Source
        let psCallback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                delegate.reconcile(trigger: .powerSourceChanged)
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(psCallback, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        // 2. IOKit RootDomain Hardware Clamshell Notification
        iokitNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        if let notifyPort = iokitNotifyPort,
           let source = IONotificationPortGetRunLoopSource(notifyPort)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            iokitRootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            if iokitRootDomain != 0 {
                let interestCallback: IOServiceInterestCallback = { refcon, _, _, _ in
                    guard let refcon = refcon else { return }
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    Task { @MainActor in
                        delegate.syncLidAndReconcile()
                    }
                }
                _ = IOServiceAddInterestNotification(
                    notifyPort,
                    iokitRootDomain,
                    kIOGeneralInterest,
                    interestCallback,
                    context,
                    &iokitNotification
                )
            }
        }

        // 3. Thermal State Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalStateChanged(_:)),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        // 4. Display Sleep / Wake Notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceScreensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceScreensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceAppLifecycleChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceAppLifecycleChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // 5. System Power Sleep Monitor (IORegisterForSystemPower)
        systemPowerMonitor.start(
            canSystemSleep: { [weak self] in
                guard let self = self else { return true }
                return !self.viewModel.sessionMode.isActive
            },
            onWillSleep: {
                // Forced/emergency sleep: unfreeze immediately so apps never remain stopped
                AppFreezer.shared.unfreezeAllApps()
            },
            onDidWake: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.viewModel.sessionMode.isActive {
                        PowerManager.shared.verifyAndRepairActivePowerState(
                            preventDisplaySleep: Preferences.shared.preventDisplaySleep
                        )
                    }
                    self.reconcile(trigger: .systemDidWake)
                }
            }
        )
    }

    private func teardownEventMonitoring() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
        if iokitNotification != 0 {
            IOObjectRelease(iokitNotification)
            iokitNotification = 0
        }
        if iokitRootDomain != 0 {
            IOObjectRelease(iokitRootDomain)
            iokitRootDomain = 0
        }
        if let notifyPort = iokitNotifyPort {
            IONotificationPortDestroy(notifyPort)
            iokitNotifyPort = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleThermalStateChanged(_ notification: Notification) {
        reconcile(trigger: .thermalStateChanged)
    }

    @objc private func handleWorkspaceScreensDidSleep(_ notification: Notification) {
        syncLidAndReconcile()
    }

    @objc private func handleWorkspaceScreensDidWake(_ notification: Notification) {
        // Do NOT unfreeze if the MacBook lid is still closed (dark wake / external monitor tickle)
        if !DisplayManager.shared.hasLid() || !DisplayManager.shared.isLidClosed() {
            AppFreezer.shared.unfreezeAllApps()
        }
        syncLidAndReconcile()
    }

    @objc private func handleWorkspaceAppLifecycleChanged(_ notification: Notification) {
        guard viewModel.sessionMode.isActive,
              DisplayManager.shared.hasLid(),
              DisplayManager.shared.isLidClosed() else {
            return
        }
        reconcile(trigger: .freezePreferenceChanged)
    }

    private func syncLidAndReconcile() {
        let hasLid = DisplayManager.shared.hasLid()
        let currentLidClosed = hasLid ? DisplayManager.shared.isLidClosed() : false

        if !currentLidClosed && lastLidClosedState {
            // Lid opened: unfreeze apps and complete any deferred sleep restoration
            AppFreezer.shared.unfreezeAllApps()

            if case .pendingSleepRestore(let reason) = viewModel.sessionMode,
               !didPromptPendingRestoreForCurrentOpen {
                didPromptPendingRestoreForCurrentOpen = true
                lastLidClosedState = currentLidClosed
                completePendingSleepRestore(reason: reason)
                return
            }
        }

        if currentLidClosed {
            didPromptPendingRestoreForCurrentOpen = false
        }

        lastLidClosedState = currentLidClosed
        reconcile(trigger: .lidStateChanged)
    }

    // MARK: - Reconciliation Pipeline

    private nonisolated static func captureSystemSnapshot(forceSudoRefresh: Bool = false) -> SystemSnapshot {
        let hasLid = DisplayManager.shared.hasLid()
        let isLidClosed = hasLid ? DisplayManager.shared.isLidClosed() : false
        let battery = PowerManager.shared.getBatteryStatus()
        let thermalState = ProcessInfo.processInfo.thermalState
        let kernelSleepDisabled = PowerManager.shared.checkLidSleepDisabled()
        let sudoConfigured = PowerManager.shared.isPasswordlessSudoConfigured(forceRefresh: forceSudoRefresh)

        return SystemSnapshot(
            hasLid: hasLid,
            isLidClosed: isLidClosed,
            battery: battery,
            thermalState: thermalState,
            kernelSleepDisabled: kernelSleepDisabled,
            sudoConfigured: sudoConfigured
        )
    }

    private func captureSnapshot(forceSudoRefresh: Bool = false) -> SystemSnapshot {
        let base = Self.captureSystemSnapshot(forceSudoRefresh: forceSudoRefresh)
        return snapshotWithFrozenCount(base, count: AppFreezer.shared.frozenCount)
    }

    private func snapshotWithFrozenCount(_ snapshot: SystemSnapshot, count: Int) -> SystemSnapshot {
        SystemSnapshot(
            hasLid: snapshot.hasLid,
            isLidClosed: snapshot.isLidClosed,
            battery: snapshot.battery,
            thermalState: snapshot.thermalState,
            kernelSleepDisabled: snapshot.kernelSleepDisabled,
            sudoConfigured: snapshot.sudoConfigured,
            frozenAppCount: count
        )
    }

    private func reconcile(trigger: ReconcileTrigger) {
        var snapshot = captureSnapshot()
        popoverRefreshGeneration &+= 1
        viewModel.snapshot = snapshot

        if viewModel.sessionMode.isActive {
            switch trigger {
            case .launchAdoption, .safetyPreferenceChanged:
                let violation = SafetyEvaluator.evaluate(
                    battery: snapshot.battery,
                    thermalState: snapshot.thermalState,
                    preferences: Preferences.shared,
                    treatSeriousThermalAsViolation: false
                )
                if let reason = violation.reason {
                    stopKeepAwakeSession(reason: reason)
                    return
                }
                evaluateDebouncedGuards(snapshot: snapshot)

            case .powerSourceChanged, .thermalStateChanged, .driftCheck, .systemDidWake, .startSession, .extendSession, .lidStateChanged, .freezePreferenceChanged:
                evaluateDebouncedGuards(snapshot: snapshot)
            }

            if case .launchAdoption = trigger {
                PowerManager.shared.startNativePowerAssertion(
                    preventDisplaySleep: Preferences.shared.preventDisplaySleep
                )
                startDriftVerificationTimer()
            }

            if case .driftCheck = trigger {
                PowerManager.shared.verifyAndRepairActivePowerState(
                    preventDisplaySleep: Preferences.shared.preventDisplaySleep
                )
            }

            // Reconcile hardware effects when active
            let effectiveScreenOff = SudoFeatureAvailability.effectiveLidFeatureToggle(
                storedValue: Preferences.shared.turnOffScreenOnLidClose,
                sudoConfigured: snapshot.sudoConfigured
            )
            let effectiveFreeze = SudoFeatureAvailability.effectiveLidFeatureToggle(
                storedValue: Preferences.shared.appFreezeOnLidCloseEnabled,
                sudoConfigured: snapshot.sudoConfigured
            )

            let shouldFreeze = effectiveFreeze && snapshot.hasLid && snapshot.isLidClosed
            _ = AppFreezer.shared.reconcileFrozenApps(shouldFreeze: shouldFreeze, preferences: Preferences.shared)

            if effectiveScreenOff && snapshot.hasLid && snapshot.isLidClosed {
                DisplayManager.shared.turnOffDisplay(force: false)
            }

            updateClosedLidReconcileTimer(
                shouldRun: snapshot.hasLid && snapshot.isLidClosed && effectiveFreeze
            )
        } else {
            stopClosedLidReconcileTimer()
            AppFreezer.shared.unfreezeAllApps()
            powerDebouncer.cancelAll()
        }

        snapshot = snapshotWithFrozenCount(snapshot, count: AppFreezer.shared.frozenCount)
        viewModel.snapshot = snapshot
        refreshAuxiliaryState(with: snapshot)
    }

    private func evaluateDebouncedGuards(snapshot: SystemSnapshot) {
        powerDebouncer.evaluate(
            battery: snapshot.battery,
            isActive: viewModel.sessionMode.isActive,
            acOnlyEnabled: Preferences.shared.acOnlyModeEnabled,
            batteryCutoffEnabled: Preferences.shared.batteryCutoffEnabled,
            cutoffThreshold: Preferences.shared.batteryCutoffThreshold,
            readLatestBattery: { PowerManager.shared.getBatteryStatus() },
            onStop: { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.stopKeepAwakeSession(reason: reason)
                }
            }
        )

        thermalGuard.evaluate(
            state: snapshot.thermalState,
            isActive: viewModel.sessionMode.isActive,
            guardEnabled: Preferences.shared.thermalGuardEnabled,
            onWarnSerious: {
                AppNotificationService.shared.send(
                    GhostNotificationFactory.thermalWarning(),
                    playSound: Preferences.shared.soundNotificationsEnabled
                )
            },
            onCutoff: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.stopKeepAwakeSession(reason: .thermalOverheat)
                }
            }
        )
    }

    // MARK: - Session Management

    func startKeepAwakeSession(durationSeconds: Int) {
        let snapshot = captureSnapshot()
        popoverRefreshGeneration &+= 1
        viewModel.snapshot = snapshot

        let violation = SafetyEvaluator.evaluate(
            battery: snapshot.battery,
            thermalState: snapshot.thermalState,
            preferences: Preferences.shared,
            treatSeriousThermalAsViolation: false
        )
        if let reason = violation.reason {
            let description = rejectionMessage(for: reason)
            viewModel.showBanner(.warning, title: "Cannot Start Session", message: description)
            AppNotificationService.shared.send(
                GhostNotificationFactory.startBlocked(reasonMessage: description),
                playSound: Preferences.shared.soundNotificationsEnabled
            )
            return
        }

        let wasActive = viewModel.sessionMode.isActive
        let needsSleepDisable = !wasActive || !snapshot.kernelSleepDisabled

        if needsSleepDisable {
            let success = PowerManager.shared.setLidSleep(
                disabled: true,
                allowInteractivePrompt: true,
                preventDisplaySleep: Preferences.shared.preventDisplaySleep
            )
            guard success else {
                refreshPopoverData()
                viewModel.showBanner(
                    .error,
                    title: "Authentication Required",
                    message: "Ghost Mode needs administrator authorization or Passwordless Sudo (Prefs tab) to disable closed-lid sleep."
                )
                return
            }
        } else {
            PowerManager.shared.startNativePowerAssertion(
                preventDisplaySleep: Preferences.shared.preventDisplaySleep
            )
        }

        viewModel.dismissBanner()

        if durationSeconds > 0 {
            let endDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
            viewModel.sessionMode = .activeFinite(endDate: endDate, totalDuration: durationSeconds)
        } else {
            viewModel.sessionMode = .activeIndefinite
        }

        if !wasActive {
            thermalGuard.resetForNewSession()
            powerDebouncer.cancelAll()
        }

        startSessionTimers(for: viewModel.sessionMode)
        reconcile(trigger: .startSession)

        if Preferences.shared.autoClosePopoverOnStart {
            statusBarController.closePopover()
        }

        AppNotificationService.shared.requestAuthorizationIfNeeded()
        let durationText = durationSeconds > 0 ? formatDurationHuman(durationSeconds) : "Indefinite"
        AppNotificationService.shared.send(
            GhostNotificationFactory.sessionStarted(
                durationText: durationText,
                isLidClosed: viewModel.snapshot.hasLid && viewModel.snapshot.isLidClosed
            ),
            playSound: Preferences.shared.soundNotificationsEnabled
        )
    }

    func extendSession(by seconds: Int) {
        guard seconds > 0 else { return }

        switch viewModel.sessionMode {
        case .idle, .pendingSleepRestore:
            startKeepAwakeSession(durationSeconds: seconds)

        case .activeFinite(let currentEnd, let totalDuration):
            let now = Date()
            let newEnd = max(now, currentEnd).addingTimeInterval(TimeInterval(seconds))
            let remaining = max(1, Int(ceil(newEnd.timeIntervalSince(now))))
            let newTotal = max(totalDuration + seconds, remaining)

            viewModel.sessionMode = .activeFinite(endDate: newEnd, totalDuration: newTotal)
            startSessionTimers(for: viewModel.sessionMode)
            reconcile(trigger: .extendSession)

            AppNotificationService.shared.send(
                GhostNotificationFactory.sessionExtended(
                    addedText: formatDurationHuman(seconds),
                    remainingText: formatDurationHuman(remaining),
                    isLidClosed: viewModel.snapshot.hasLid && viewModel.snapshot.isLidClosed
                ),
                playSound: Preferences.shared.soundNotificationsEnabled
            )

        case .activeIndefinite:
            let newEnd = Date().addingTimeInterval(TimeInterval(seconds))
            viewModel.sessionMode = .activeFinite(endDate: newEnd, totalDuration: seconds)
            startSessionTimers(for: viewModel.sessionMode)
            reconcile(trigger: .extendSession)

            AppNotificationService.shared.send(
                GhostNotificationFactory.timerSwitchedFromIndefinite(
                    durationText: formatDurationHuman(seconds),
                    isLidClosed: viewModel.snapshot.hasLid && viewModel.snapshot.isLidClosed
                ),
                playSound: Preferences.shared.soundNotificationsEnabled
            )
        }
    }

    func stopKeepAwakeSession(reason: SessionStopReason) {
        stopSessionTimers()
        powerDebouncer.cancelAll()
        thermalGuard.resetForNewSession()
        AppFreezer.shared.unfreezeAllApps()
        PowerManager.shared.stopNativePowerAssertion()

        let hasLid = DisplayManager.shared.hasLid()
        let isLidClosed = hasLid && DisplayManager.shared.isLidClosed()
        let sudoConfigured = PowerManager.shared.isPasswordlessSudoConfigured()

        if reason != .userManual && isLidClosed && !sudoConfigured {
            _ = PowerManager.shared.setLidSleep(disabled: false, allowInteractivePrompt: false)
            if PowerManager.shared.checkLidSleepDisabled() {
                viewModel.sessionMode = .pendingSleepRestore(reason)
                didPromptPendingRestoreForCurrentOpen = false
                viewModel.showBanner(
                    .warning,
                    title: "Sleep Restore Pending",
                    message: "Session stopped behind closed lid without passwordless sudo. Open the lid to restore normal sleep."
                )
                refreshPopoverData()
                sendStopNotification(for: reason, pendingRestore: true)
                return
            }
        }

        let restored = PowerManager.shared.setLidSleep(disabled: false, allowInteractivePrompt: !isLidClosed)
        if !restored && PowerManager.shared.checkLidSleepDisabled() {
            viewModel.sessionMode = .pendingSleepRestore(reason)
            viewModel.showBanner(
                .warning,
                title: "Sleep Restore Pending",
                message: "Normal sleep has not been restored yet. Click Restore Normal Sleep or configure Passwordless Sudo."
            )
        } else {
            viewModel.sessionMode = .idle
            viewModel.dismissBanner()
            sendStopNotification(for: reason, pendingRestore: false)
        }

        refreshPopoverData()
    }

    private func completePendingSleepRestore(reason: SessionStopReason) {
        let restored = PowerManager.shared.setLidSleep(disabled: false, allowInteractivePrompt: true)
        if restored || !PowerManager.shared.checkLidSleepDisabled() {
            viewModel.sessionMode = .idle
            viewModel.dismissBanner()
            sendStopNotification(for: reason, pendingRestore: false)
        } else {
            viewModel.showBanner(
                .warning,
                title: "Sleep Restore Pending",
                message: "Authorization was cancelled. Click Restore Normal Sleep to re-enable closed-lid sleep."
            )
        }
        refreshPopoverData()
    }

    // MARK: - Timers (Active-Only)

    private func startSessionTimers(for mode: SessionMode) {
        stopSessionTimers()

        guard mode.isActive else { return }

        startDriftVerificationTimer()

        if case .activeFinite(let endDate, _) = mode {
            let interval = max(0.1, endDate.timeIntervalSinceNow)
            let expTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopKeepAwakeSession(reason: .timerExpired)
                }
            }
            RunLoop.current.add(expTimer, forMode: .common)
            sessionExpirationTimer = expTimer

            if Preferences.shared.showCountdownInMenuBar {
                scheduleNextAdaptiveBadgeTick()
            }
        }
    }

    private func scheduleNextAdaptiveBadgeTick() {
        countdownBadgeTimer?.invalidate()
        guard case .activeFinite(let endDate, _) = viewModel.sessionMode,
              Preferences.shared.showCountdownInMenuBar else {
            countdownBadgeTimer = nil
            return
        }

        let rem = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        guard rem > 0 else { return }

        let interval: TimeInterval
        if rem > 60 {
            let secInCurrentMin = rem % 60
            interval = TimeInterval(secInCurrentMin == 0 ? 60 : secInCurrentMin)
        } else {
            interval = 1.0
        }

        let timer = Timer.scheduledTimer(withTimeInterval: max(0.5, interval), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.statusBarController.updateStatusButton(
                    sessionMode: self.viewModel.sessionMode,
                    snapshot: self.viewModel.snapshot,
                    showCountdown: Preferences.shared.showCountdownInMenuBar
                )
                self.scheduleNextAdaptiveBadgeTick()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        countdownBadgeTimer = timer
    }

    private func startDriftVerificationTimer() {
        driftVerificationTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.viewModel.sessionMode.isActive else { return }
                self.reconcile(trigger: .driftCheck)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        driftVerificationTimer = timer
    }

    private func updateClosedLidReconcileTimer(shouldRun: Bool) {
        if !shouldRun {
            stopClosedLidReconcileTimer()
            return
        }

        if #available(macOS 14.0, *) {
            // Zero-polling event-driven CoreAudio output listener on macOS 14+
            closedLidReconcileTimer?.invalidate()
            closedLidReconcileTimer = nil
            AppFreezer.shared.startAudioActivityMonitor { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self,
                          self.viewModel.sessionMode.isActive,
                          DisplayManager.shared.hasLid(),
                          DisplayManager.shared.isLidClosed() else {
                        self?.stopClosedLidReconcileTimer()
                        return
                    }
                    self.reconcile(trigger: .freezePreferenceChanged)
                }
            }
            return
        }

        guard closedLidReconcileTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.viewModel.sessionMode.isActive,
                      DisplayManager.shared.hasLid(),
                      DisplayManager.shared.isLidClosed() else {
                    self?.stopClosedLidReconcileTimer()
                    return
                }
                self.reconcile(trigger: .freezePreferenceChanged)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        closedLidReconcileTimer = timer
    }

    private func stopClosedLidReconcileTimer() {
        AppFreezer.shared.stopAudioActivityMonitor()
        closedLidReconcileTimer?.invalidate()
        closedLidReconcileTimer = nil
    }

    private func stopSessionTimers() {
        sessionExpirationTimer?.invalidate()
        sessionExpirationTimer = nil
        countdownBadgeTimer?.invalidate()
        countdownBadgeTimer = nil
        driftVerificationTimer?.invalidate()
        driftVerificationTimer = nil
        stopClosedLidReconcileTimer()
    }

    private func startPopoverRefreshTimer() {
        stopPopoverRefreshTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.viewModel.isPopoverVisible else {
                    self?.stopPopoverRefreshTimer()
                    return
                }
                self.refreshPopoverData()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        popoverRefreshTimer = timer
    }

    private func stopPopoverRefreshTimer() {
        popoverRefreshTimer?.invalidate()
        popoverRefreshTimer = nil
    }

    // MARK: - Preferences & System Actions

    private func handleToggleCountdown() {
        if Preferences.shared.showCountdownInMenuBar {
            scheduleNextAdaptiveBadgeTick()
        } else {
            countdownBadgeTimer?.invalidate()
            countdownBadgeTimer = nil
        }
        refreshPopoverData()
    }

    private func handleToggleLogin() {
        let target = !LoginItemManager.isEnabled()
        do {
            try LoginItemManager.setEnabled(target)
            viewModel.needsLoginApproval = LoginItemManager.needsApproval()
            if viewModel.needsLoginApproval {
                viewModel.showBanner(
                    .info,
                    title: "Login Item Approval Needed",
                    message: "Approve Ghost Mode in System Settings → General → Login Items."
                )
            } else {
                viewModel.dismissBanner()
            }
        } catch {
            viewModel.needsLoginApproval = LoginItemManager.needsApproval()
            viewModel.showBanner(
                .error,
                title: "Launch at Login Failed",
                message: error.localizedDescription
            )
        }
        refreshPopoverData()
    }

    private func handleSetupOrRevokeSudo() {
        guard !isPrivilegedActionInFlight else { return }
        isPrivilegedActionInFlight = true
        defer { isPrivilegedActionInFlight = false }

        let currentlyConfigured = PowerManager.shared.isPasswordlessSudoConfigured(forceRefresh: true)
        if currentlyConfigured {
            let result = PowerManager.shared.performPrivilegedAction(.revokePasswordlessSudo)
            PowerManager.shared.invalidateSudoCache()
            let nowConfigured = PowerManager.shared.isPasswordlessSudoConfigured(forceRefresh: true)
            if result.cancelled {
                viewModel.showBanner(
                    .info,
                    title: "Revocation Cancelled",
                    message: "No changes were made to passwordless sudo access."
                )
            } else if !result.success {
                viewModel.showBanner(
                    .error,
                    title: "Revocation Failed",
                    message: result.errorMessage ?? "Could not obtain administrator privileges to remove Ghost Mode sudoers rules."
                )
            } else if nowConfigured {
                viewModel.showBanner(
                    .error,
                    title: "Other Sudoers Rule Active",
                    message: "Removed Ghost Mode sudoers rules, but another system sudoers entry still grants passwordless pmset."
                )
            } else {
                viewModel.showBanner(
                    .info,
                    title: "Authorization Revoked",
                    message: "Passwordless sudo removed. macOS will prompt when sleep settings change."
                )
            }
        } else {
            guard let username = PowerManager.currentVerifiedUsername() else {
                viewModel.showBanner(
                    .error,
                    title: "Setup Failed",
                    message: "Could not verify the current interactive macOS account."
                )
                return
            }

            let result = PowerManager.shared.performPrivilegedAction(
                .configurePasswordlessSudo(username: username)
            )
            PowerManager.shared.invalidateSudoCache()
            let nowConfigured = PowerManager.shared.isPasswordlessSudoConfigured(forceRefresh: true)
            if result.cancelled {
                viewModel.showBanner(
                    .info,
                    title: "Setup Cancelled",
                    message: "No changes were made."
                )
            } else if result.success && nowConfigured {
                viewModel.showBanner(
                    .info,
                    title: "Passwordless Sudo Configured",
                    message: "Ghost Mode can now manage closed-lid sleep without password prompts."
                )
            } else {
                viewModel.showBanner(
                    .error,
                    title: "Setup Failed",
                    message: result.errorMessage ?? "Passwordless sudo could not be configured."
                )
            }
        }

        reconcile(trigger: .freezePreferenceChanged)
        refreshPopoverData(forceSudoRefresh: true)
    }

    private func unfreezeAllNow() {
        let count = AppFreezer.shared.frozenCount
        AppFreezer.shared.unfreezeAllApps()
        if count > 0 {
            viewModel.showBanner(
                .info,
                title: "Apps Resumed",
                message: "Resumed \(count) frozen \(count == 1 ? "app" : "apps")."
            )
        }
        refreshPopoverData()
    }

    private func resetDefaults() {
        Preferences.shared.resetToDefaults()
        NSApp.setActivationPolicy(Preferences.shared.showInDock ? .regular : .accessory)
        handleToggleCountdown()
        if viewModel.sessionMode.isActive {
            PowerManager.shared.startNativePowerAssertion(
                preventDisplaySleep: Preferences.shared.preventDisplaySleep
            )
            reconcile(trigger: .safetyPreferenceChanged)
        } else {
            refreshPopoverData()
        }
        viewModel.showBanner(
            .info,
            title: "Defaults Restored",
            message: "All Ghost Mode preferences have been reset to defaults."
        )
    }

    private func copyDiagnostics() {
        let sessionSummary: String
        switch viewModel.sessionMode {
        case .idle:
            sessionSummary = "idle"
        case .activeFinite(let endDate, let totalDuration):
            let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
            sessionSummary = "activeFinite(remaining=\(remaining)s, total=\(totalDuration)s)"
        case .activeIndefinite:
            sessionSummary = "activeIndefinite"
        case .pendingSleepRestore(let reason):
            sessionSummary = "pendingSleepRestore(\(reason))"
        }

        let prefs = Preferences.shared
        let prefsLines = [
            "defaultDuration=\(prefs.defaultDuration)s",
            "preventDisplaySleep=\(prefs.preventDisplaySleep)",
            "turnOffScreenOnLidClose=\(prefs.turnOffScreenOnLidClose)",
            "appFreezeOnLidCloseEnabled=\(prefs.appFreezeOnLidCloseEnabled)",
            "keepAudioActiveOnLidClose=\(prefs.keepAudioActiveOnLidClose)",
            "acOnlyModeEnabled=\(prefs.acOnlyModeEnabled)",
            "batteryCutoffEnabled=\(prefs.batteryCutoffEnabled)",
            "batteryCutoffThreshold=\(prefs.batteryCutoffThreshold)%",
            "thermalGuardEnabled=\(prefs.thermalGuardEnabled)",
            "autoClosePopoverOnStart=\(prefs.autoClosePopoverOnStart)",
            "autoStartOnLaunch=\(prefs.autoStartOnLaunch)",
            "showCountdownInMenuBar=\(prefs.showCountdownInMenuBar)",
            "soundNotificationsEnabled=\(prefs.soundNotificationsEnabled)",
            "showInDock=\(prefs.showInDock)",
            "appFreezeWhitelistCount=\(prefs.appFreezeWhitelist.count)",
            "audioFilterMode=\(prefs.audioFilterMode.rawValue)"
        ].joined(separator: ", ")

        let frozenCount = AppFreezer.shared.frozenCount

        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = Self.captureSystemSnapshot(forceSudoRefresh: true)
            let assertionSummary = PowerManager.shared.currentPowerAssertionSummary()
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let thermalLabel: String
            switch snapshot.thermalState {
            case .nominal: thermalLabel = "nominal"
            case .fair: thermalLabel = "fair"
            case .serious: thermalLabel = "serious"
            case .critical: thermalLabel = "critical"
            @unknown default: thermalLabel = "unknown"
            }

            let batteryLabel: String
            if let bat = snapshot.battery {
                let timeStr = bat.timeRemainingMinutes.map { "\($0)m" } ?? "n/a"
                batteryLabel = "\(bat.percent)% (isAC=\(bat.isAC), isCharging=\(bat.isCharging), timeRemaining=\(timeStr))"
            } else {
                batteryLabel = "none"
            }

            let report = """
            \(AppMetadata.name) v\(AppMetadata.version) (\(AppMetadata.bundleIdentifier))
            macOS: \(osVersion)
            Session: \(sessionSummary)
            Lid: hasLid=\(snapshot.hasLid), isLidClosed=\(snapshot.isLidClosed)
            SleepDisabled: \(snapshot.kernelSleepDisabled ? 1 : 0) (sudoConfigured=\(snapshot.sudoConfigured))
            Thermal: \(thermalLabel)
            Battery: \(batteryLabel)
            Assertions: \(assertionSummary)
            FrozenApps: \(frozenCount)
            Preferences: \(prefsLines)
            """

            await MainActor.run { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self?.viewModel.showBanner(
                    .info,
                    title: "Diagnostics Copied",
                    message: "Version, power, thermal, assertion, and preference diagnostics copied to clipboard."
                )
            }
        }
    }

    // MARK: - Popover & UI Data Refresh

    private func refreshPopoverData(forceSudoRefresh: Bool = false, includeAuxiliary: Bool? = nil) {
        if isPopoverRefreshInFlight {
            if forceSudoRefresh {
                pendingForcedSudoRefresh = true
                popoverRefreshGeneration &+= 1
            }
            return
        }

        let collectAuxiliary = includeAuxiliary ?? viewModel.isPopoverVisible
        let collectPrefsTelemetry = collectAuxiliary && (viewModel.selectedTab == .prefs || forceSudoRefresh)
        isPopoverRefreshInFlight = true
        popoverRefreshGeneration &+= 1
        let generation = popoverRefreshGeneration

        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = Self.captureSystemSnapshot(forceSudoRefresh: forceSudoRefresh)
            let activeAudioPids: Set<pid_t> = collectAuxiliary ? AppFreezer.shared.getActiveAudioPids() : []
            let needsLoginApproval = collectPrefsTelemetry ? LoginItemManager.needsApproval() : false
            let cpuSample = collectPrefsTelemetry ? ProcessDiagnostics.sampleProcessCPU() : (percent: 0.0, needsFollowup: false)
            let ghostMemMB = collectAuxiliary ? ProcessDiagnostics.getMemoryFootprintMB() : 0.0

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isPopoverRefreshInFlight = false

                if generation == self.popoverRefreshGeneration {
                    self.auxRefreshGeneration &+= 1
                    let updatedSnapshot = self.snapshotWithFrozenCount(
                        snapshot,
                        count: AppFreezer.shared.frozenCount
                    )
                    self.viewModel.snapshot = updatedSnapshot
                    if collectAuxiliary {
                        self.applyAuxiliaryState(
                            snapshot: updatedSnapshot,
                            activeAudioPids: activeAudioPids,
                            needsLoginApproval: needsLoginApproval,
                            ghostCPU: collectPrefsTelemetry ? cpuSample.percent : self.viewModel.ghostCPU,
                            ghostMemMB: ghostMemMB,
                            updatePrefsTelemetry: collectPrefsTelemetry
                        )
                        if collectPrefsTelemetry && cpuSample.needsFollowup {
                            self.scheduleTelemetryWarmupFollowup()
                        }
                    } else {
                        self.statusBarController.updateStatusButton(
                            sessionMode: self.viewModel.sessionMode,
                            snapshot: updatedSnapshot,
                            showCountdown: Preferences.shared.showCountdownInMenuBar
                        )
                    }
                }

                if self.pendingForcedSudoRefresh {
                    self.pendingForcedSudoRefresh = false
                    self.refreshPopoverData(forceSudoRefresh: true, includeAuxiliary: includeAuxiliary)
                }
            }
        }
    }

    private func refreshAuxiliaryState(with snapshot: SystemSnapshot) {
        statusBarController.updateStatusButton(
            sessionMode: viewModel.sessionMode,
            snapshot: snapshot,
            showCountdown: Preferences.shared.showCountdownInMenuBar
        )

        guard viewModel.isPopoverVisible else { return }

        let collectPrefsTelemetry = (viewModel.selectedTab == .prefs)
        auxRefreshGeneration &+= 1
        let generation = auxRefreshGeneration

        Task.detached(priority: .userInitiated) { [weak self] in
            let activeAudioPids = AppFreezer.shared.getActiveAudioPids()
            let needsLoginApproval = collectPrefsTelemetry ? LoginItemManager.needsApproval() : false
            let cpuSample = collectPrefsTelemetry ? ProcessDiagnostics.sampleProcessCPU() : (percent: 0.0, needsFollowup: false)
            let ghostMemMB = ProcessDiagnostics.getMemoryFootprintMB()

            await MainActor.run { [weak self] in
                guard let self = self,
                      generation == self.auxRefreshGeneration,
                      self.viewModel.isPopoverVisible else { return }
                let updatedSnapshot = self.snapshotWithFrozenCount(
                    self.viewModel.snapshot,
                    count: AppFreezer.shared.frozenCount
                )
                self.viewModel.snapshot = updatedSnapshot
                self.applyAuxiliaryState(
                    snapshot: updatedSnapshot,
                    activeAudioPids: activeAudioPids,
                    needsLoginApproval: needsLoginApproval,
                    ghostCPU: collectPrefsTelemetry ? cpuSample.percent : self.viewModel.ghostCPU,
                    ghostMemMB: ghostMemMB,
                    updatePrefsTelemetry: collectPrefsTelemetry
                )
                if collectPrefsTelemetry && cpuSample.needsFollowup {
                    self.scheduleTelemetryWarmupFollowup()
                }
            }
        }
    }

    private func scheduleTelemetryWarmupFollowup() {
        telemetryFollowupWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.viewModel.isPopoverVisible,
                  self.viewModel.selectedTab == .prefs else {
                return
            }
            self.refreshPopoverData(forceSudoRefresh: false, includeAuxiliary: true)
        }
        telemetryFollowupWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func applyAuxiliaryState(
        snapshot: SystemSnapshot,
        activeAudioPids: Set<pid_t>,
        needsLoginApproval: Bool,
        ghostCPU: Double,
        ghostMemMB: Double,
        updatePrefsTelemetry: Bool
    ) {
        viewModel.runningApps = buildRunningAppEntries(activeAudioPids: activeAudioPids)
        viewModel.ghostMemMB = ghostMemMB
        if updatePrefsTelemetry {
            viewModel.needsLoginApproval = needsLoginApproval
            viewModel.ghostCPU = ghostCPU
        }

        statusBarController.updateStatusButton(
            sessionMode: viewModel.sessionMode,
            snapshot: snapshot,
            showCountdown: Preferences.shared.showCountdownInMenuBar
        )
    }

    private func buildRunningAppEntries(activeAudioPids: Set<pid_t>) -> [AppEntry] {
        let currentPid = getpid()

        return NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                app.processIdentifier != currentPid &&
                !AppFreezer.shared.isProtectedSystemBundleIdentifier(app.bundleIdentifier ?? "") &&
                !(app.localizedName ?? "").isEmpty
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app in
                let name = app.localizedName ?? "Unknown"
                let bid = app.bundleIdentifier
                let isPlaying = AppFreezer.shared.isAppProducingAudio(app, activePids: activeAudioPids)
                let isFrozen = AppFreezer.shared.isAppFrozen(app)
                let id = "\(bid ?? name)-\(app.processIdentifier)"
                return AppEntry(
                    id: id,
                    pid: app.processIdentifier,
                    name: name,
                    bundleIdentifier: bid,
                    icon: app.icon,
                    isPlayingAudio: isPlaying,
                    isFrozen: isFrozen
                )
            }
    }

    // MARK: - Messaging Helpers

    private func rejectionMessage(for reason: SessionStopReason) -> String {
        switch reason {
        case .unpluggedAC:
            return "Only Keep Awake on AC Power is enabled. Connect power or disable AC-Only in Safety."
        case .lowBattery(let pct):
            return "Battery is at \(pct)%, at or below your \(Preferences.shared.batteryCutoffThreshold)% cutoff."
        case .thermalOverheat:
            return "System thermal pressure is critical. Wait for Mac temperature to cool down."
        case .userManual, .timerExpired:
            return "Safety checks prevented starting the session."
        }
    }

    private func sendStopNotification(for reason: SessionStopReason, pendingRestore: Bool) {
        AppNotificationService.shared.send(
            GhostNotificationFactory.sessionStopped(reason: reason, pendingRestore: pendingRestore),
            playSound: Preferences.shared.soundNotificationsEnabled
        )
    }
}
