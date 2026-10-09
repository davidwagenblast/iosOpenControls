import SwiftUI
import UserNotifications

final class ParentAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await ParentModel.shared.syncAll()
        return .newData
    }
}

@main
struct OpenControlsParentApp: App {
    @UIApplicationDelegateAdaptor(ParentAppDelegate.self) private var delegate
    @StateObject private var model = ParentModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ParentRoot()
                .environmentObject(model)
                .task { await model.syncAll() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await model.syncAll() } }
                }
        }
    }
}
