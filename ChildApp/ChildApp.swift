import SwiftUI

final class ChildAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// Silent push from CloudKit: the parent changed something.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await ChildModel.shared.syncNow()
        return .newData
    }
}

@main
struct OpenControlsKidApp: App {
    @UIApplicationDelegateAdaptor(ChildAppDelegate.self) private var delegate
    @StateObject private var model = ChildModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        model.refreshAuthorization()
                        model.reloadFromStore()
                        Task { await model.syncNow() }
                    } else if phase == .background {
                        model.lockSetup()
                    }
                }
        }
    }
}
