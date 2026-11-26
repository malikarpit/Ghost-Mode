//
//  DisplayManager.swift
//  Ghost Mode
//

import CoreGraphics
import Foundation
import IOKit

// MARK: - Display & Clamshell Hardware Manager

public final class DisplayManager {
    public static let shared = DisplayManager()

    private let displaySleepCooldown: TimeInterval = 4.0
    private let sleepQueue = DispatchQueue(label: "com.arpit.ghostmode.displaysleep", qos: .userInitiated)
    private var lastDisplaySleepRequest: Date = .distantPast

    private init() {}

    public func hasLid() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        if let prop = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
            _ = prop.takeRetainedValue()
            return true
        }
        return false
    }

    public func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        if let propRef = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
            let prop = propRef.takeRetainedValue()
            if let b = prop as? Bool { return b }
            if let num = prop as? NSNumber { return num.boolValue }
            if CFGetTypeID(prop) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((prop as! CFBoolean))
            }
        }
        return false
    }

    public func turnOffDisplay(force: Bool = false) {
        sleepQueue.async { [self] in
            let now = Date()
            if !force {
                guard now.timeIntervalSince(self.lastDisplaySleepRequest) >= self.displaySleepCooldown else { return }
            }
            guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
            self.lastDisplaySleepRequest = now

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return
                }
            } catch {
                // Fall through to IODisplayWrangler fallback.
            }

            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IODisplayWrangler"))
            if service != IO_OBJECT_NULL {
                IORegistryEntrySetCFProperty(service, "IORequestIdle" as CFString, kCFBooleanTrue)
                IOObjectRelease(service)
            }
        }
    }
}
