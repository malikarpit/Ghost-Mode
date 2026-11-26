//
//  AppFreezer.swift
//  Ghost Mode
//

import AppKit
import CoreAudio
import Darwin
import Foundation
import IOKit.pwr_mgt

// MARK: - Pre-allocated Async-Signal-Safe Crash Recovery Buffer

private let kMaxCrashTrackedFrozenPids = 1024
private let gCrashFrozenPids: UnsafeMutablePointer<pid_t> = {
    let ptr = UnsafeMutablePointer<pid_t>.allocate(capacity: kMaxCrashTrackedFrozenPids)
    ptr.initialize(repeating: 0, count: kMaxCrashTrackedFrozenPids)
    return ptr
}()
private var gCrashFrozenCount: Int32 = 0

// MARK: - App Freezer & Battery Isolation Manager

public final class AppFreezer {
    public static let shared = AppFreezer()

    public private(set) var frozenRecords: [pid_t: FrozenProcessRecord] = [:]

    // Event-driven CoreAudio output monitor (macOS 14.0+)
    private let audioMonitorQueue = DispatchQueue(label: "com.arpit.GhostMode.audioMonitor", qos: .utility)
    private var isAudioMonitorActive = false
    private var audioMonitorChangeHandler: (() -> Void)?
    private var audioProcessListListenerBlock: AudioObjectPropertyListenerBlock?
    private var audioProcessOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredAudioProcessObjects: Set<AudioObjectID> = []
    private var pendingAudioDebounceWorkItem: DispatchWorkItem?

    public var frozenCount: Int {
        frozenRecords.count
    }

    public func isPidFrozen(_ pid: pid_t) -> Bool {
        frozenRecords[pid] != nil
    }

    public func isAppFrozen(_ app: NSRunningApplication) -> Bool {
        frozenRecords[app.processIdentifier] != nil
    }

    /// Permanent core OS & Ghost Mode bundle identifiers (NEVER frozen under any circumstance).
    public let systemProtectedIdentifiers: Set<String> = [
        "com.arpit.GhostMode",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.SystemUIServer",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.bluetoothd",
        "com.apple.airportd",
        "com.apple.coreaudiod",
        "com.apple.universalaccessd",
        "com.apple.accessibility.heard",
        "com.apple.SecurityAgent",
        "com.apple.authorizationhost",
        "com.apple.UserNotificationCenter",
        "com.apple.CoreServicesUIAgent",
        "com.apple.OSDUIHelper",
        "com.apple.TextInputMenuAgent",
        "com.apple.TextInputSwitcher"
    ]

    public func isProtectedSystemBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        if systemProtectedIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return bundleIdentifier.hasPrefix("com.apple.security.") ||
            bundleIdentifier.hasPrefix("com.apple.systemuiserver") ||
            bundleIdentifier.hasPrefix("com.apple.WindowManager")
    }

    /// Async-signal-safe fatal crash handler wired via `sigaction` (`SA_RESETHAND | SA_NODEFER`).
    /// Reads only the pre-allocated C PID table and sends `SIGCONT` before re-raising default signal.
    public static let fatalCrashSignalHandler: @convention(c) (Int32) -> Void = { sig in
        let count = Int(gCrashFrozenCount)
        let limit = count < kMaxCrashTrackedFrozenPids ? count : kMaxCrashTrackedFrozenPids
        if limit > 0 {
            for i in 0..<limit {
                let pid = gCrashFrozenPids[i]
                if pid > 100 {
                    _ = Darwin.kill(pid, SIGCONT)
                }
            }
        }
        Darwin.signal(sig, SIG_DFL)
        Darwin.kill(Darwin.getpid(), sig)
    }

    private init() {}

    // MARK: - Pure Policy & Safety Helpers

    public static func isAudioAllowed(
        bundleID: String?,
        appName: String,
        mode: AudioFilterMode,
        blockedApps: [String],
        allowedApps: [String]
    ) -> Bool {
        var identifiers: [String] = []
        if let bundleID = bundleID, !bundleID.isEmpty {
            identifiers.append(bundleID)
        }
        if !appName.isEmpty {
            identifiers.append(appName)
        }

        switch mode {
        case .allowAllExceptBlocked:
            let blocked = Set(blockedApps)
            return !identifiers.contains(where: { blocked.contains($0) })
        case .allowOnlySelected:
            let allowed = Set(allowedApps)
            guard !allowed.isEmpty else { return false }
            return identifiers.contains(where: { allowed.contains($0) })
        }
    }

    private static let cryptexPrefixes = [
        "/System/Volumes/Preboot/Cryptexes/Incoming/OS",
        "/System/Volumes/Preboot/Cryptexes/OS",
        "/System/Volumes/Preboot/Cryptexes/App",
        "/System/Cryptexes/Incoming/OS",
        "/System/Cryptexes/OS",
        "/System/Cryptexes/App"
    ]

    public static func normalizeExecutablePath(_ path: String) -> String {
        for prefix in cryptexPrefixes {
            if path.hasPrefix(prefix + "/") {
                return String(path.dropFirst(prefix.count))
            }
        }
        return path
    }

    public static func isProtectedSystemExecutablePath(_ path: String) -> Bool {
        let normalized = normalizeExecutablePath(path)
        if normalized.hasPrefix("/System/Applications/") {
            return false
        }
        if normalized.hasPrefix("/System/Library/") ||
            normalized.hasPrefix("/System/iOSSupport/System/Library/") ||
            normalized.hasPrefix("/Library/Apple/") {
            return true
        }
        if normalized.hasPrefix("/bin/") ||
            normalized.hasPrefix("/sbin/") ||
            normalized.hasPrefix("/usr/bin/") ||
            normalized.hasPrefix("/usr/sbin/") ||
            normalized.hasPrefix("/usr/libexec/") {
            return true
        }
        return false
    }

    public static func shouldFreezeApp(
        bundleID: String?,
        appName: String,
        executablePath: String,
        systemProtectedIdentifiers: Set<String>,
        whitelist: Set<String>,
        keepAudio: Bool,
        isProducingAudio: Bool,
        audioMode: AudioFilterMode,
        blockedAudioApps: [String],
        allowedAudioApps: [String]
    ) -> Bool {
        let bid = bundleID ?? ""
        if (!bid.isEmpty && systemProtectedIdentifiers.contains(bid)) ||
            (!bid.isEmpty && whitelist.contains(bid)) ||
            (!appName.isEmpty && whitelist.contains(appName)) {
            return false
        }
        if !executablePath.isEmpty && isProtectedSystemExecutablePath(executablePath) {
            return false
        }
        if keepAudio && isProducingAudio {
            let allowedAudio = isAudioAllowed(
                bundleID: bundleID,
                appName: appName,
                mode: audioMode,
                blockedApps: blockedAudioApps,
                allowedApps: allowedAudioApps
            )
            if allowedAudio {
                return false
            }
        }
        return true
    }

    public static func shouldResumeProcess(
        record: FrozenProcessRecord,
        liveStartSec: UInt64,
        liveStartUsec: UInt64,
        isStopped: Bool
    ) -> Bool {
        return isStopped && record.startSec == liveStartSec && record.startUsec == liveStartUsec
    }

    // MARK: - Kernel Process Inspection

    private static func readProcessBSDInfo(pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }
        return info
    }

    public static func readProcessStartAndStatus(pid: pid_t) -> (startSec: UInt64, startUsec: UInt64, isStopped: Bool)? {
        guard let info = readProcessBSDInfo(pid: pid) else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec, info.pbi_status == UInt32(SSTOP))
    }

    private typealias ResponsibilityGetPidFn = @convention(c) (pid_t) -> pid_t

    private static let responsibilityGetPidForPid: ResponsibilityGetPidFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibilityGetPidFn.self)
    }()

    public static func responsiblePid(of pid: pid_t) -> pid_t {
        guard pid > 0, let fn = responsibilityGetPidForPid else { return pid }
        let resp = fn(pid)
        return resp > 0 ? resp : pid
    }

    private static func listAllPids() -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        let capacity = Int(estimatedCount) + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytes = Int32(capacity * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&buffer, bytes)
        guard actualCount > 0 else { return [] }
        return buffer.prefix(Int(actualCount)).filter { $0 > 0 }
    }

    private func getExecutablePath(of pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            return String(cString: pathBuffer)
        }
        return ""
    }

    private func isPid(_ candidatePid: pid_t, descendantOf ancestorPid: pid_t) -> Bool {
        var cursor = candidatePid
        var hops = 0
        while cursor > 1 && hops < 12 {
            guard let info = Self.readProcessBSDInfo(pid: cursor) else { return false }
            let ppid = pid_t(info.pbi_ppid)
            if ppid == ancestorPid { return true }
            if ppid <= 1 || ppid == cursor { return false }
            cursor = ppid
            hops += 1
        }
        return false
    }

    private func bundlePathMatches(executablePath: String, app: NSRunningApplication) -> Bool {
        guard !executablePath.isEmpty, let bundlePath = app.bundleURL?.path, !bundlePath.isEmpty else {
            return false
        }
        let normExec = Self.normalizeExecutablePath(executablePath)
        let normBundle = Self.normalizeExecutablePath(bundlePath)
        for (exec, bundle) in [(executablePath, bundlePath), (normExec, normBundle)] {
            let normalizedPrefix = bundle.hasSuffix("/") ? bundle : bundle + "/"
            if exec == bundle || exec.hasPrefix(normalizedPrefix) {
                return true
            }
        }
        return false
    }

    private func isPid(_ candidatePid: pid_t, ownedByApp app: NSRunningApplication, executablePath: String) -> Bool {
        let appPid = app.processIdentifier
        if candidatePid == appPid { return true }
        if Self.responsiblePid(of: candidatePid) == appPid { return true }
        if isPid(candidatePid, descendantOf: appPid) { return true }
        if bundlePathMatches(executablePath: executablePath, app: app) { return true }
        return false
    }

    // MARK: - Dynamic Audio Detection

    /// Computes which CoreAudio process objects were added or removed since the last snapshot.
    public static func computeAudioProcessMonitorDiff(
        current: Set<AudioObjectID>,
        desired: Set<AudioObjectID>
    ) -> (added: Set<AudioObjectID>, removed: Set<AudioObjectID>) {
        (added: desired.subtracting(current), removed: current.subtracting(desired))
    }

    /// Starts event-driven CoreAudio process/output monitoring (macOS 14.0+).
    /// Falls back to no-op on macOS 12–13 where `AppDelegate` uses a relaxed fallback timer.
    public func startAudioActivityMonitor(
        debounceSeconds: TimeInterval = 0.15,
        onChange: @escaping () -> Void
    ) {
        guard #available(macOS 14.0, *) else { return }
        audioMonitorQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioMonitorChangeHandler = onChange
            guard !self.isAudioMonitorActive else { return }
            self.isAudioMonitorActive = true

            let systemObject = AudioObjectID(kAudioObjectSystemObject)
            var processListAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self = self, #available(macOS 14.0, *) else { return }
                self.syncAudioProcessListenersOnQueue()
                self.scheduleAudioChangeNotificationOnQueue(debounceSeconds: debounceSeconds)
            }
            self.audioProcessListListenerBlock = listBlock

            if AudioObjectHasProperty(systemObject, &processListAddress) {
                _ = AudioObjectAddPropertyListenerBlock(
                    systemObject,
                    &processListAddress,
                    self.audioMonitorQueue,
                    listBlock
                )
            }

            self.audioProcessOutputListenerBlock = { [weak self] _, _ in
                guard let self = self else { return }
                self.scheduleAudioChangeNotificationOnQueue(debounceSeconds: debounceSeconds)
            }

            self.syncAudioProcessListenersOnQueue()
        }
    }

    /// Stops all CoreAudio property listeners registered by `startAudioActivityMonitor`.
    public func stopAudioActivityMonitor() {
        guard #available(macOS 14.0, *) else { return }
        audioMonitorQueue.async { [weak self] in
            guard let self = self else { return }
            self.isAudioMonitorActive = false
            self.pendingAudioDebounceWorkItem?.cancel()
            self.pendingAudioDebounceWorkItem = nil
            self.audioMonitorChangeHandler = nil

            let systemObject = AudioObjectID(kAudioObjectSystemObject)
            if let listBlock = self.audioProcessListListenerBlock {
                var processListAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessObjectList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                _ = AudioObjectRemovePropertyListenerBlock(
                    systemObject,
                    &processListAddress,
                    self.audioMonitorQueue,
                    listBlock
                )
                self.audioProcessListListenerBlock = nil
            }

            if let outputBlock = self.audioProcessOutputListenerBlock {
                var outputAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningOutput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var runningAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunning,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                for processObj in self.monitoredAudioProcessObjects {
                    _ = AudioObjectRemovePropertyListenerBlock(processObj, &outputAddress, self.audioMonitorQueue, outputBlock)
                    _ = AudioObjectRemovePropertyListenerBlock(processObj, &runningAddress, self.audioMonitorQueue, outputBlock)
                }
            }
            self.monitoredAudioProcessObjects.removeAll()
            self.audioProcessOutputListenerBlock = nil
        }
    }

    @available(macOS 14.0, *)
    private func syncAudioProcessListenersOnQueue() {
        guard isAudioMonitorActive, let outputBlock = audioProcessOutputListenerBlock else { return }
        let desired = Set(fetchCurrentAudioProcessObjects())
        let diff = Self.computeAudioProcessMonitorDiff(current: monitoredAudioProcessObjects, desired: desired)

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for removedObj in diff.removed {
            _ = AudioObjectRemovePropertyListenerBlock(removedObj, &outputAddress, audioMonitorQueue, outputBlock)
            _ = AudioObjectRemovePropertyListenerBlock(removedObj, &runningAddress, audioMonitorQueue, outputBlock)
        }

        for addedObj in diff.added {
            if AudioObjectHasProperty(addedObj, &outputAddress) {
                _ = AudioObjectAddPropertyListenerBlock(addedObj, &outputAddress, audioMonitorQueue, outputBlock)
            } else if AudioObjectHasProperty(addedObj, &runningAddress) {
                _ = AudioObjectAddPropertyListenerBlock(addedObj, &runningAddress, audioMonitorQueue, outputBlock)
            }
        }

        monitoredAudioProcessObjects = desired
    }

    private func scheduleAudioChangeNotificationOnQueue(debounceSeconds: TimeInterval) {
        guard isAudioMonitorActive else { return }
        pendingAudioDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isAudioMonitorActive, let handler = self.audioMonitorChangeHandler else {
                return
            }
            DispatchQueue.main.async(execute: handler)
        }
        pendingAudioDebounceWorkItem = workItem
        audioMonitorQueue.asyncAfter(deadline: .now() + max(0.05, debounceSeconds), execute: workItem)
    }

    @available(macOS 14.0, *)
    private func fetchCurrentAudioProcessObjects() -> [AudioObjectID] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var processListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(systemObject, &processListAddress) else {
            return []
        }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &processListAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &processListAddress, 0, nil, &dataSize, &processObjects) == noErr else {
            return []
        }

        let actualCount = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        return Array(processObjects.prefix(actualCount))
    }

    @available(macOS 14.0, *)
    private func getCoreAudioActiveOutputPids() -> Set<pid_t> {
        var result = Set<pid_t>()
        for processObj in fetchCurrentAudioProcessObjects() {
            var isOutputRunning = false
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(processObj, &outputAddress) {
                var value: UInt32 = 0
                var valueSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(processObj, &outputAddress, 0, nil, &valueSize, &value) == noErr {
                    isOutputRunning = (value != 0)
                }
            } else {
                var runningAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunning,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                if AudioObjectHasProperty(processObj, &runningAddress) {
                    var value: UInt32 = 0
                    var valueSize = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(processObj, &runningAddress, 0, nil, &valueSize, &value) == noErr {
                        isOutputRunning = (value != 0)
                    }
                }
            }
            guard isOutputRunning else { continue }

            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectHasProperty(processObj, &pidAddress),
               AudioObjectGetPropertyData(processObj, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
               pid > 0 {
                result.insert(pid)
            }
        }
        return result
    }

    public func getActiveAudioPids() -> Set<pid_t> {
        var audioPids = Set<pid_t>()
        var assertionsRef: Unmanaged<CFDictionary>?
        if IOPMCopyAssertionsByProcess(&assertionsRef) == kIOReturnSuccess,
           let dict = assertionsRef?.takeRetainedValue() as? [NSNumber: NSArray] {
            for (pidNum, arr) in dict {
                for item in arr {
                    guard let assertion = item as? [String: Any] else { continue }
                    let name = (assertion["AssertName"] as? String) ?? ""
                    let onBehalf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                        ?? (assertion["AssertionOnBehalfOfPID"] as? Int32)
                        ?? 0

                    if name.localizedCaseInsensitiveContains("audio") ||
                        name.localizedCaseInsensitiveContains("media") ||
                        name.localizedCaseInsensitiveContains("speaker") ||
                        name.localizedCaseInsensitiveContains("headphone") ||
                        name.localizedCaseInsensitiveContains("airpods") ||
                        name.localizedCaseInsensitiveContains("bluetooth") {
                        if onBehalf > 0 {
                            audioPids.insert(onBehalf)
                        } else {
                            audioPids.insert(pidNum.int32Value)
                        }
                    }
                }
            }
        }

        if #available(macOS 14.0, *) {
            audioPids.formUnion(getCoreAudioActiveOutputPids())
        }

        return audioPids
    }

    public func isAppProducingAudio(_ app: NSRunningApplication, activePids: Set<pid_t>) -> Bool {
        let appPid = app.processIdentifier
        if activePids.contains(appPid) {
            return true
        }
        for aPid in activePids {
            if Self.responsiblePid(of: aPid) == appPid {
                return true
            }
            if isPid(aPid, descendantOf: appPid) {
                return true
            }
            let execPath = getExecutablePath(of: aPid)
            if bundlePathMatches(executablePath: execPath, app: app) {
                return true
            }
        }
        return false
    }

    // MARK: - Reconciliation & Process Control

    private static func ancestorPids(of pid: pid_t) -> Set<pid_t> {
        var result = Set<pid_t>()
        var cursor = pid
        var hops = 0
        while cursor > 1 && hops < 32 {
            result.insert(cursor)
            let resp = responsiblePid(of: cursor)
            if resp > 1 {
                result.insert(resp)
            }
            guard let info = readProcessBSDInfo(pid: cursor) else { break }
            let ppid = pid_t(info.pbi_ppid)
            if ppid <= 1 || ppid == cursor || result.contains(ppid) {
                break
            }
            cursor = ppid
            hops += 1
        }
        return result
    }

    @discardableResult
    public func reconcileFrozenApps(shouldFreeze: Bool, preferences: Preferences = .shared) -> Int {
        guard shouldFreeze else {
            unfreezeAllApps()
            return 0
        }

        let currentPid = getpid()
        let currentUid = getuid()
        let immunePids = Self.ancestorPids(of: currentPid)
        let whitelist = Set(preferences.appFreezeWhitelist)
        let keepAudio = preferences.keepAudioActiveOnLidClose
        let audioMode = preferences.audioFilterMode
        let blockedAudio = preferences.audioBlockedApps
        let allowedAudio = preferences.audioAllowedApps

        let activeAudioPids = getActiveAudioPids()
        let allRunningApps = NSWorkspace.shared.runningApplications
        let regularApps = allRunningApps.filter { $0.activationPolicy == .regular }

        var targetFreezeMainPids = Set<pid_t>()
        var targetFreezeHelperPids = Set<pid_t>()
        var targetFrozenApps: [NSRunningApplication] = []
        var protectedOrKeptApps: [NSRunningApplication] = []
        var keptAudioPids = Set<pid_t>(immunePids)

        for app in allRunningApps where app.activationPolicy != .regular {
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            if isProtectedSystemBundleIdentifier(bid) ||
                (!bid.isEmpty && whitelist.contains(bid)) ||
                (!name.isEmpty && whitelist.contains(name)) {
                protectedOrKeptApps.append(app)
            }
        }

        for app in regularApps {
            let pid = app.processIdentifier
            guard pid > 100 && pid != currentPid && !immunePids.contains(pid) else {
                protectedOrKeptApps.append(app)
                continue
            }

            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""

            if isProtectedSystemBundleIdentifier(bid) {
                protectedOrKeptApps.append(app)
                continue
            }

            if let bsd = Self.readProcessBSDInfo(pid: pid), bsd.pbi_uid != currentUid {
                protectedOrKeptApps.append(app)
                continue
            }

            let appExecPath = getExecutablePath(of: pid)
            let isProducingAudio = isAppProducingAudio(app, activePids: activeAudioPids)
            let shouldFreezeApp = Self.shouldFreezeApp(
                bundleID: app.bundleIdentifier,
                appName: name,
                executablePath: appExecPath,
                systemProtectedIdentifiers: systemProtectedIdentifiers,
                whitelist: whitelist,
                keepAudio: keepAudio,
                isProducingAudio: isProducingAudio,
                audioMode: audioMode,
                blockedAudioApps: blockedAudio,
                allowedAudioApps: allowedAudio
            )

            if !shouldFreezeApp {
                protectedOrKeptApps.append(app)
                if keepAudio && isProducingAudio && Self.isAudioAllowed(
                    bundleID: app.bundleIdentifier,
                    appName: name,
                    mode: audioMode,
                    blockedApps: blockedAudio,
                    allowedApps: allowedAudio
                ) {
                    // CRITICAL: Never SIGSTOP the main PID or audio helpers of an allowed active audio player.
                    keptAudioPids.insert(pid)
                    for aPid in activeAudioPids {
                        let aExecPath = getExecutablePath(of: aPid)
                        if isPid(aPid, ownedByApp: app, executablePath: aExecPath) {
                            keptAudioPids.insert(aPid)
                        }
                    }
                }
                continue
            }

            targetFreezeMainPids.insert(pid)
            targetFrozenApps.append(app)

            // If this app is producing audio that is NOT kept alive, freeze its verified user-owned helpers too.
            if isProducingAudio {
                for aPid in activeAudioPids {
                    guard aPid > 100 && aPid != currentPid && !keptAudioPids.contains(aPid) else { continue }
                    let aExecPath = getExecutablePath(of: aPid)
                    guard !aExecPath.isEmpty, !Self.isProtectedSystemExecutablePath(aExecPath) else { continue }
                    guard let bsd = Self.readProcessBSDInfo(pid: aPid), bsd.pbi_uid == currentUid else { continue }
                    if isPid(aPid, ownedByApp: app, executablePath: aExecPath) {
                        targetFreezeHelperPids.insert(aPid)
                    }
                }
            }
        }

        // Freeze verified user-owned non-protected helper PIDs alongside main .regular frozen apps.
        if !targetFrozenApps.isEmpty {
            let nonTargetRegularPids = Set(regularApps.map(\.processIdentifier)).subtracting(targetFreezeMainPids)
            for helperPid in Self.listAllPids() {
                guard helperPid > 100 &&
                        helperPid != currentPid &&
                        !targetFreezeMainPids.contains(helperPid) &&
                        !targetFreezeHelperPids.contains(helperPid) &&
                        !keptAudioPids.contains(helperPid) &&
                        !nonTargetRegularPids.contains(helperPid) else {
                    continue
                }
                guard let bsd = Self.readProcessBSDInfo(pid: helperPid),
                      bsd.pbi_uid == currentUid,
                      bsd.pbi_status != UInt32(SZOMB) else {
                    continue
                }
                let execPath = getExecutablePath(of: helperPid)
                guard !execPath.isEmpty, !Self.isProtectedSystemExecutablePath(execPath) else { continue }
                if protectedOrKeptApps.contains(where: { isPid(helperPid, ownedByApp: $0, executablePath: execPath) }) {
                    continue
                }
                if targetFrozenApps.contains(where: { isPid(helperPid, ownedByApp: $0, executablePath: execPath) }) {
                    targetFreezeHelperPids.insert(helperPid)
                }
            }
        }

        // Also handle standalone/non-regular audio helper PIDs when audio keep-alive is disabled.
        if !keepAudio {
            for aPid in activeAudioPids {
                guard aPid > 100 && aPid != currentPid && !keptAudioPids.contains(aPid) else { continue }
                guard let bsd = Self.readProcessBSDInfo(pid: aPid),
                      bsd.pbi_uid == currentUid,
                      bsd.pbi_status != UInt32(SZOMB) else {
                    continue
                }
                let execPath = getExecutablePath(of: aPid)
                guard !execPath.isEmpty, !Self.isProtectedSystemExecutablePath(execPath) else { continue }

                if protectedOrKeptApps.contains(where: { isPid(aPid, ownedByApp: $0, executablePath: execPath) }) ||
                    isOwnedByProtectedOrWhitelistedApp(
                        pid: aPid,
                        executablePath: execPath,
                        runningApps: allRunningApps,
                        whitelist: whitelist
                    ) {
                    continue
                }
                if !targetFreezeMainPids.contains(aPid) {
                    targetFreezeHelperPids.insert(aPid)
                }
            }
        }

        let targetFreezePids = targetFreezeMainPids.union(targetFreezeHelperPids)

        // Diff Step 1: Resume PIDs no longer targeted for freezing (main/parent PIDs before helpers).
        let pidsToResume = frozenRecords.keys.filter { !targetFreezePids.contains($0) }
        let orderedResumePids = orderedPidsParentFirst(pidsToResume, regularApps: regularApps)
        for pid in orderedResumePids {
            if let record = frozenRecords[pid] {
                resumeProcessIfMatching(record)
            }
            frozenRecords.removeValue(forKey: pid)
        }

        // Diff Step 2: Freeze helper/child PIDs BEFORE main .regular PIDs to avoid parent-child IPC deadlocks.
        let orderedFreezePids = Array(targetFreezeHelperPids) + Array(targetFreezeMainPids)
        for pid in orderedFreezePids where frozenRecords[pid] == nil {
            guard let bsd = Self.readProcessBSDInfo(pid: pid), bsd.pbi_status != UInt32(SZOMB) else { continue }
            if Darwin.kill(pid, SIGSTOP) == 0 {
                frozenRecords[pid] = FrozenProcessRecord(
                    pid: pid,
                    startSec: bsd.pbi_start_tvsec,
                    startUsec: bsd.pbi_start_tvusec
                )
            }
        }

        syncCrashBufferAndPersist()
        return frozenRecords.count
    }

    private func orderedPidsParentFirst(_ pids: [pid_t], regularApps: [NSRunningApplication]) -> [pid_t] {
        let regularSet = Set(regularApps.map(\.processIdentifier))
        return pids.sorted { lhs, rhs in
            let lMain = regularSet.contains(lhs)
            let rMain = regularSet.contains(rhs)
            if lMain != rMain { return lMain }
            return lhs < rhs
        }
    }

    private func isOwnedByProtectedOrWhitelistedApp(
        pid: pid_t,
        executablePath: String,
        runningApps: [NSRunningApplication],
        whitelist: Set<String>
    ) -> Bool {
        for app in runningApps {
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            let isProtectedOrWhitelisted = systemProtectedIdentifiers.contains(bid)
                || whitelist.contains(bid)
                || whitelist.contains(name)
            if isProtectedOrWhitelisted && isPid(pid, ownedByApp: app, executablePath: executablePath) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func freezeNonWhitelistedApps() -> Int {
        guard Preferences.shared.appFreezeOnLidCloseEnabled else { return 0 }
        return reconcileFrozenApps(shouldFreeze: true, preferences: .shared)
    }

    public func unfreezeAllApps() {
        guard !frozenRecords.isEmpty else {
            syncCrashBufferAndPersist()
            return
        }
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let orderedPids = orderedPidsParentFirst(Array(frozenRecords.keys), regularApps: regularApps)
        for pid in orderedPids {
            if let record = frozenRecords[pid] {
                resumeProcessIfMatching(record)
            }
        }
        frozenRecords.removeAll()
        syncCrashBufferAndPersist()
    }

    public func recoverOrphanedFrozenApps() {
        let url = persistenceURL()
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([FrozenProcessRecord].self, from: data) else {
            return
        }

        for record in records {
            resumeProcessIfMatching(record)
        }

        if frozenRecords.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            syncCrashBufferAndPersist()
        }
    }

    private func resumeProcessIfMatching(_ record: FrozenProcessRecord) {
        guard let live = Self.readProcessStartAndStatus(pid: record.pid) else { return }
        if Self.shouldResumeProcess(
            record: record,
            liveStartSec: live.startSec,
            liveStartUsec: live.startUsec,
            isStopped: live.isStopped
        ) {
            _ = Darwin.kill(record.pid, SIGCONT)
        }
    }

    // MARK: - Crash Buffer & Disk Persistence

    private func persistenceURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return baseDir
            .appendingPathComponent("GhostMode", isDirectory: true)
            .appendingPathComponent("frozen_pids.json")
    }

    private func syncCrashBufferAndPersist() {
        // Update pre-allocated C table on main queue (zero allocations in signal handler).
        gCrashFrozenCount = 0
        let pids = Array(frozenRecords.keys.prefix(kMaxCrashTrackedFrozenPids))
        for (idx, pid) in pids.enumerated() {
            gCrashFrozenPids[idx] = pid
        }
        gCrashFrozenCount = Int32(pids.count)

        let url = persistenceURL()
        if frozenRecords.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Array(frozenRecords.values))
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort persistence; in-memory crash table remains active.
        }
    }
}
