import Foundation
import FamilyControls
import ManagedSettings

/// Translates a `ShieldDecision` into `ManagedSettingsStore` state. All shielding goes
/// through one named store, so applying a new decision fully replaces the old one.
struct ShieldApplier {
    private let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(rawValue: "opencontrols.main"))

    func clear() {
        store.clearAllSettings()
    }

    func apply(_ decision: ShieldDecision, selections: [UUID: FamilyActivitySelection], tamperProtection: Bool) {
        if decision.blockAll {
            var allowedApps = Set<ApplicationToken>()
            var allowedWeb = Set<WebDomainToken>()
            for id in decision.allowedGroupIDs {
                guard let selection = selections[id] else { continue }
                allowedApps.formUnion(selection.applicationTokens)
                allowedWeb.formUnion(selection.webDomainTokens)
            }
            store.shield.applications = nil
            store.shield.webDomains = nil
            store.shield.applicationCategories = ShieldSettings.ActivityCategoryPolicy.all(except: allowedApps)
            store.shield.webDomainCategories = ShieldSettings.ActivityCategoryPolicy.all(except: allowedWeb)
        } else {
            var apps = Set<ApplicationToken>()
            var categories = Set<ActivityCategoryToken>()
            var web = Set<WebDomainToken>()
            for id in decision.shieldedGroups.keys {
                guard let selection = selections[id] else { continue }
                apps.formUnion(selection.applicationTokens)
                categories.formUnion(selection.categoryTokens)
                web.formUnion(selection.webDomainTokens)
            }
            store.shield.applications = apps.isEmpty ? nil : apps
            store.shield.webDomains = web.isEmpty ? nil : web
            store.shield.applicationCategories = categories.isEmpty ? nil : ShieldSettings.ActivityCategoryPolicy.specific(categories)
            store.shield.webDomainCategories = categories.isEmpty ? nil : ShieldSettings.ActivityCategoryPolicy.specific(categories)
        }

        // Stop the obvious ways around a limit: moving the clock and deleting the app.
        store.dateAndTime.requireAutomaticDateAndTime = tamperProtection ? true : nil
        store.application.denyAppRemoval = tamperProtection ? true : nil
    }
}
