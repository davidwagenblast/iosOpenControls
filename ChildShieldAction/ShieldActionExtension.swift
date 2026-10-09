import ManagedSettings
import ManagedSettingsUI

/// Handles taps on the shield's buttons. "OK" closes the blocked app; the secondary
/// button queues a request for the parent (sent by the child app, which can use the network).
final class ShieldActionExtension: ShieldActionDelegate {
    private let responder = ShieldResponder()

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(responder.handle(action: action, target: .application(application)))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(responder.handle(action: action, target: .webDomain(webDomain)))
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(responder.handle(action: action, target: .category(category)))
    }
}
