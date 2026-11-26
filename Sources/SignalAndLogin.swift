//
//  SignalAndLogin.swift
//  Ghost Mode
//

import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Signal Manager

public final class SignalManager {
    private var sources: [DispatchSourceSignal] = []

    public init() {}

    public func install(onGracefulExit: @escaping () -> Void) {
        sources.forEach { $0.cancel() }
        sources.removeAll()

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                onGracefulExit()
            }
            src.resume()
            sources.append(src)
        }

        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = AppFreezer.fatalCrashSignalHandler
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = SA_RESETHAND | SA_NODEFER
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL] {
            sigaction(sig, &sa, nil)
        }
    }
}

// MARK: - Login Item Manager (SMAppService on macOS 13+, LaunchAgent on macOS 12)

public enum LoginItemManager {
    private static let legacyLabel = "com.arpit.ghostmode"

    private static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    public static func isEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return FileManager.default.fileExists(atPath: legacyPlistURL.path)
        }
    }

    public static func needsApproval() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if FileManager.default.fileExists(atPath: legacyPlistURL.path) {
                runLaunchctl(["bootout", "gui/\(getuid())/\(legacyLabel)"])
                try? FileManager.default.removeItem(at: legacyPlistURL)
            }

            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } else {
            if enabled {
                let execPath = Bundle.main.executablePath
                    ?? "\(Bundle.main.bundlePath)/Contents/MacOS/GhostMode"
                let plist: [String: Any] = [
                    "Label": legacyLabel,
                    "ProgramArguments": [execPath],
                    "RunAtLoad": true
                ]
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist,
                    format: .xml,
                    options: 0
                )
                try FileManager.default.createDirectory(
                    at: legacyPlistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: legacyPlistURL, options: .atomic)
                runLaunchctl(["bootstrap", "gui/\(getuid())", legacyPlistURL.path])
            } else {
                runLaunchctl(["bootout", "gui/\(getuid())/\(legacyLabel)"])
                try? FileManager.default.removeItem(at: legacyPlistURL)
            }
        }
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - System Power Sleep & Wake Monitor (IORegisterForSystemPower)

public final class SystemPowerSleepMonitor {
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?

    private var canSystemSleepHandler: (() -> Bool)?
    private var onWillSleepHandler: (() -> Void)?
    private var onDidWakeHandler: (() -> Void)?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        canSystemSleep: @escaping () -> Bool,
        onWillSleep: @escaping () -> Void,
        onDidWake: @escaping () -> Void
    ) {
        self.canSystemSleepHandler = canSystemSleep
        self.onWillSleepHandler = onWillSleep
        self.onDidWakeHandler = onDidWake

        guard rootPort == 0 else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let port = IORegisterForSystemPower(refcon, &notifyPort, Self.powerCallback, &notifierObject)
        guard port != 0 else { return }
        rootPort = port

        if let notifyPort = notifyPort,
           let source = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if notifierObject != 0 {
            IODeregisterForSystemPower(&notifierObject)
            notifierObject = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let np = notifyPort {
            IONotificationPortDestroy(np)
            notifyPort = nil
        }
        canSystemSleepHandler = nil
        onWillSleepHandler = nil
        onDidWakeHandler = nil
    }

    // `iokit_common_msg(...)` macros from <IOKit/IOMessage.h> are not directly imported by Swift.
    private static let msgCanSystemSleep: UInt32 = 0xe000_0270    // kIOMessageCanSystemSleep
    private static let msgSystemWillSleep: UInt32 = 0xe000_0280   // kIOMessageSystemWillSleep
    private static let msgSystemHasPoweredOn: UInt32 = 0xe000_0300 // kIOMessageSystemHasPoweredOn

    private static let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
        guard let refcon = refcon else { return }
        let monitor = Unmanaged<SystemPowerSleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let arg = Int(bitPattern: messageArgument)

        switch messageType {
        case msgCanSystemSleep:
            let canSleep = monitor.canSystemSleepHandler?() ?? true
            if canSleep {
                IOAllowPowerChange(monitor.rootPort, arg)
            } else {
                IOCancelPowerChange(monitor.rootPort, arg)
            }
        case msgSystemWillSleep:
            monitor.onWillSleepHandler?()
            IOAllowPowerChange(monitor.rootPort, arg)
        case msgSystemHasPoweredOn:
            monitor.onDidWakeHandler?()
        default:
            break
        }
    }
}
