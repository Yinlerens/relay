import Foundation
import UIKit
@preconcurrency import UserNotifications

/// Native iOS local notifications for generation/Agent errors (lock-screen/background delivery + test trigger).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKey.errorNotifications) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.errorNotifications) }
    }

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        } catch {
            return false
        }
    }

    func notifyError(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        forceInForeground: Bool = false
    ) {
        guard forceInForeground || isEnabled else { return }
        if !forceInForeground && UIApplication.shared.applicationState == .active {
            // Foreground errors already present the in-app Banner + Haptics + in-chat error card.
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty else { return }

        Task { @MainActor in
            let status = await authorizationStatus()
            guard status == .authorized || status == .provisional || status == .ephemeral else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = cleanTitle.isEmpty ? "Relay 报错提醒" : cleanTitle
            content.body = String(cleanBody.prefix(240))
            content.sound = .default
            content.interruptionLevel = .active

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
