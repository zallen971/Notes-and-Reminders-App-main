//
//  ReminderApp.swift
//  Reminder
//
//  Created by Zachary Allen on 1/2/25.
//

import SwiftUI
import UserNotifications

// MARK: - App Entry Point
@main
struct ReminderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // lets repeating reminders switch to a repeating notification once their start date has passed
            if newPhase == .active {
                ReminderStore.shared.rescheduleAllNotifications()
            }
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DataManager.shared.removeOrphanedAttachments()

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // buttons shown on reminder notifications; neither opens the app
        let doneAction = UNNotificationAction(identifier: ReminderStore.doneAction, title: "Mark as Done")
        let snoozeAction = UNNotificationAction(identifier: ReminderStore.snoozeAction, title: "Snooze \(ReminderStore.snoozeMinutes) Minutes")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderStore.notificationCategory, actions: [doneAction, snoozeAction], intentIdentifiers: [])
        ])

        // reminders scheduled by older versions get the new buttons
        ReminderStore.shared.rescheduleAllNotifications()

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            } else if granted {
                print("Notification permissions granted")
            } else {
                print("Notification permissions denied")
            }
        }
        return true
    }

    // without this, reminders that fire while the app is open are silently dropped
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // the Done and Snooze buttons on a reminder notification
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = ReminderStore.reminderID(fromNotificationIdentifier: response.notification.request.identifier) else { return }

        switch response.actionIdentifier {
        case ReminderStore.doneAction:
            ReminderStore.shared.markDone(id: id)
        case ReminderStore.snoozeAction:
            ReminderStore.shared.snooze(id: id)
        default:
            break
        }
    }
}
