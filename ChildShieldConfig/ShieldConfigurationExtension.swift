import ManagedSettings
import ManagedSettingsUI
import UIKit

/// Replaces the stock "Time Limit" screen with an explanation of *why* the app is
/// blocked (limit, bedtime, pause...) and an "ask a parent" button.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private let responder = ShieldResponder()

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        guard let token = application.token else { return fallback() }
        return build(.application(token), subject: application.localizedDisplayName)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        guard let token = application.token else { return fallback() }
        return build(.application(token), subject: application.localizedDisplayName)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        guard let token = webDomain.token else { return fallback() }
        return build(.webDomain(token), subject: webDomain.domain)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        guard let token = webDomain.token else { return fallback() }
        return build(.webDomain(token), subject: webDomain.domain)
    }

    private func build(_ target: ShieldTarget, subject: String?) -> ShieldConfiguration {
        let message = responder.message(for: target, subject: subject)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            backgroundColor: UIColor.systemBackground.withAlphaComponent(0.85),
            icon: UIImage(systemName: message.symbol),
            title: ShieldConfiguration.Label(text: message.title, color: .label),
            subtitle: ShieldConfiguration.Label(text: message.subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue,
            secondaryButtonLabel: message.askLabel.map { ShieldConfiguration.Label(text: $0, color: .systemBlue) })
    }

    private func fallback() -> ShieldConfiguration {
        let message = ShieldCopy.message(reason: nil, subject: nil, groupName: nil, canAsk: false)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            icon: UIImage(systemName: message.symbol),
            title: ShieldConfiguration.Label(text: message.title, color: .label),
            subtitle: ShieldConfiguration.Label(text: message.subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemBlue)
    }
}
