import Foundation

/// Values that differ per developer team. They are injected into each target's
/// Info.plist from `project.yml` (`OC_BUNDLE_PREFIX`), so changing the prefix in one
/// place updates entitlements, the App Group and the CloudKit container together.
enum AppConfig {
    static let defaultBundlePrefix = "com.example.opencontrols"

    static var appGroupIdentifier: String {
        infoString("OCAppGroup") ?? "group.\(defaultBundlePrefix).shared"
    }

    static var cloudKitContainerIdentifier: String {
        infoString("OCCloudKitContainer") ?? "iCloud.\(defaultBundlePrefix)"
    }

    /// URL scheme registered by the child app; pairing links look like `opencontrolskid://pair?i=...`.
    static let kidURLScheme = "opencontrolskid"

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
