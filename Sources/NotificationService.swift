//
//  NotificationService.swift
//  Ghost Mode
//

import Foundation
import UserNotifications

public final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate, NotificationSending {
    public static let shared = AppNotificationService()

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

    public func send(title: String, subtitle: String? = nil, body: String, playSound: Bool = true) {
        guard isValidAppBundle else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle = subtitle, !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.body = body
            if playSound {
                content.sound = .default
            }

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
