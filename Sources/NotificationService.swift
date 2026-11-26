//
//  NotificationService.swift
//  Ghost Mode
//
//  Concise, coalesced macOS notifications with click-to-open support.
//

import Foundation
import UserNotifications

// MARK: - Notification Copy & Coalescing Factory

public enum GhostNotificationFactory {
    public static let sessionRequestID = "com.arpit.ghostmode.session"
    public static let safetyRequestID = "com.arpit.ghostmode.safety"
    public static let welcomeRequestID = "com.arpit.ghostmode.welcome"

    public static func welcome() -> GhostNotificationPayload {
        GhostNotificationPayload(
            title: "Ghost Mode Ready",
            subtitle: nil,
            body: "Click the ghost icon in your menu bar to start a session.",
            requestIdentifier: welcomeRequestID,
            threadIdentifier: "status",
            iconStyle: .resting,
            isTimeSensitive: false
        )
    }

    public static func sessionStarted(durationText: String, isLidClosed: Bool) -> GhostNotificationPayload {
        GhostNotificationPayload(
            title: "Ghost Mode Active (\(durationText))",
            subtitle: nil,
            body: isLidClosed
                ? "Closed-lid keep-awake active. Safety guards running."
                : "Sleep disabled. Battery and thermal guards active.",
            requestIdentifier: sessionRequestID,
            threadIdentifier: "session",
            iconStyle: isLidClosed ? .stealth : .awake,
            isTimeSensitive: false
        )
    }

    public static func sessionExtended(addedText: String, remainingText: String, isLidClosed: Bool) -> GhostNotificationPayload {
        GhostNotificationPayload(
            title: "Session Extended (+\(addedText))",
            subtitle: nil,
            body: "\(remainingText) remaining before normal sleep resumes.",
            requestIdentifier: sessionRequestID,
            threadIdentifier: "session",
            iconStyle: isLidClosed ? .stealth : .awake,
            isTimeSensitive: false
        )
    }

    public static func timerSwitchedFromIndefinite(durationText: String, isLidClosed: Bool) -> GhostNotificationPayload {
        GhostNotificationPayload(
            title: "Timer Set (\(durationText))",
            subtitle: nil,
            body: "Switched from indefinite. Sleep resumes in \(durationText).",
            requestIdentifier: sessionRequestID,
            threadIdentifier: "session",
            iconStyle: isLidClosed ? .stealth : .awake,
            isTimeSensitive: false
        )
    }

    public static func thermalWarning() -> GhostNotificationPayload {
        GhostNotificationPayload(
            title: "High Temperature Warning",
            subtitle: nil,
            body: "Mac is running hot. Session stops if high heat persists.",
            requestIdentifier: safetyRequestID,
            threadIdentifier: "safety",
            iconStyle: .pendingRestore,
            isTimeSensitive: true
        )
    }

    public static func startBlocked(reasonMessage: String) -> GhostNotificationPayload {
        GhostNotificationPayload(
            title: "Cannot Start Session",
            subtitle: nil,
            body: reasonMessage,
            requestIdentifier: safetyRequestID,
            threadIdentifier: "safety",
            iconStyle: .pendingRestore,
            isTimeSensitive: false
        )
    }

    public static func sessionStopped(reason: SessionStopReason, pendingRestore: Bool) -> GhostNotificationPayload {
        switch reason {
        case .userManual:
            return GhostNotificationPayload(
                title: "Ghost Mode Off",
                subtitle: nil,
                body: "Normal sleep restored.",
                requestIdentifier: sessionRequestID,
                threadIdentifier: "session",
                iconStyle: .resting,
                isTimeSensitive: false
            )
        case .timerExpired:
            return GhostNotificationPayload(
                title: pendingRestore ? "Timer Finished · Open Lid" : "Timer Finished",
                subtitle: nil,
                body: pendingRestore
                    ? "Open the lid to restore normal sleep."
                    : "Session ended. Normal sleep restored.",
                requestIdentifier: sessionRequestID,
                threadIdentifier: "session",
                iconStyle: pendingRestore ? .pendingRestore : .resting,
                isTimeSensitive: pendingRestore
            )
        case .lowBattery(let pct):
            return GhostNotificationPayload(
                title: pendingRestore ? "Low Battery (\(pct)%) · Open Lid" : "Low Battery Cutoff (\(pct)%)",
                subtitle: nil,
                body: pendingRestore
                    ? "Keep-awake paused. Open the lid to restore sleep."
                    : "Stopped to protect battery. Normal sleep restored.",
                requestIdentifier: safetyRequestID,
                threadIdentifier: "safety",
                iconStyle: pendingRestore ? .pendingRestore : .resting,
                isTimeSensitive: true
            )
        case .unpluggedAC:
            return GhostNotificationPayload(
                title: pendingRestore ? "Charger Unplugged · Open Lid" : "Charger Unplugged",
                subtitle: nil,
                body: pendingRestore
                    ? "Keep-awake paused on battery. Open lid to restore sleep."
                    : "On battery power. Normal sleep restored.",
                requestIdentifier: safetyRequestID,
                threadIdentifier: "safety",
                iconStyle: pendingRestore ? .pendingRestore : .resting,
                isTimeSensitive: true
            )
        case .thermalOverheat:
            return GhostNotificationPayload(
                title: pendingRestore ? "Overheat Cutoff · Open Lid" : "Thermal Protection Triggered",
                subtitle: nil,
                body: pendingRestore
                    ? "Critical heat detected. Open lid to restore sleep."
                    : "Stopped due to high heat. Normal sleep restored.",
                requestIdentifier: safetyRequestID,
                threadIdentifier: "safety",
                iconStyle: pendingRestore ? .pendingRestore : .resting,
                isTimeSensitive: true
            )
        }
    }
}

// MARK: - Notification Service

public final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationSending {
    public static let shared = AppNotificationService()

    public var onNotificationActivated: (() -> Void)?

    private var isConfigured = false

    private var isValidAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public override init() {
        super.init()
    }

    public func configure() {
        guard isValidAppBundle, !isConfigured else { return }
        UNUserNotificationCenter.current().delegate = self
        isConfigured = true
    }

    public func requestAuthorizationIfNeeded() {
        guard isValidAppBundle else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    public func send(_ payload: GhostNotificationPayload, playSound: Bool = true) {
        guard isValidAppBundle else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = payload.title
            if let subtitle = payload.subtitle, !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.body = payload.body
            content.threadIdentifier = payload.threadIdentifier
            content.interruptionLevel = payload.isTimeSensitive ? .timeSensitive : .active
            if playSound {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: payload.requestIdentifier,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationActivated?()
        }
        completionHandler()
    }
}
