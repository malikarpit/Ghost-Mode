//
//  main.swift
//  Ghost Mode (macOS Keep-Awake & Display Controller)
//
//  Created & Developed by Arpit
//  Copyright © 2026 Arpit. All rights reserved.
//  Digital Identifier: com.arpit.GhostMode
//

import AppKit
import Darwin
import Foundation

var globalLockFileDescriptor: Int32 = -1

func enforceSingleInstance() -> Bool {
    let currentPid = getpid()

    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: AppMetadata.bundleIdentifier)
    for app in runningApps where app.processIdentifier != currentPid {
        print("Ghost Mode: Existing instance detected (PID \(app.processIdentifier)). Notifying running app.")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.arpit.ghostmode.showMenu"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return false
    }

    let tempDir = FileManager.default.temporaryDirectory
    let lockURL = tempDir.appendingPathComponent("ghostmode_\(getuid()).lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    if fd < 0 { return true }

    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        print("Ghost Mode: Active lock on \(lockURL.path). Existing instance running.")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.arpit.ghostmode.showMenu"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        close(fd)
        return false
    }

    globalLockFileDescriptor = fd
    return true
}

if !enforceSingleInstance() {
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
