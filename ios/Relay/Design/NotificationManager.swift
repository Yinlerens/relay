import Foundation
import UIKit
@preconcurrency import UserNotifications

/// Native iOS local notifications for generation/Agent errors with tap deep-linking.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    struct NotificationTarget: Equatable, Sendable {
        let sessionId: String?
        let tavernCharacterId: Int?
    }

    static let shared = NotificationManager()

    var onSelectTarget: (@MainActor (NotificationTarget) -> Void)? {
        didSet {
            if let target = pendingTarget, let handler = onSelectTarget {
                pendingTarget = nil
                handler(target)
            }
        }
    }

    private var pendingTarget: NotificationTarget?

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
        forceInForeground: Bool = false,
        sessionId: String? = nil,
        tavernCharacterId: Int? = nil
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

            var userInfo: [AnyHashable: Any] = [:]
            if let sessionId, !sessionId.isEmpty {
                userInfo["sessionId"] = sessionId
            }
            if let tavernCharacterId {
                userInfo["tavernCharacterId"] = tavernCharacterId
            }
            if !userInfo.isEmpty {
                content.userInfo = userInfo
            }

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func deliverTarget(_ target: NotificationTarget) {
        guard target.sessionId != nil || target.tavernCharacterId != nil else { return }
        if let onSelectTarget {
            onSelectTarget(target)
        } else {
            pendingTarget = target
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String
        let tavernCharacterId: Int? = {
            if let intVal = info["tavernCharacterId"] as? Int { return intVal }
            if let numVal = info["tavernCharacterId"] as? NSNumber { return numVal.intValue }
            return nil
        }()
        let target = NotificationTarget(sessionId: sessionId, tavernCharacterId: tavernCharacterId)
        await MainActor.run {
            NotificationManager.shared.deliverTarget(target)
        }
    }
}
