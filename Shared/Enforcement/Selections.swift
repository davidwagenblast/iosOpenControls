import Foundation
import FamilyControls
import ManagedSettings

/// Which apps/categories/websites belong to each group. Chosen on the child's device
/// (tokens are opaque and device-local) and stored per group ID.
struct SelectionBook {
    let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    func selection(for groupID: UUID) -> FamilyActivitySelection {
        guard let data = store.selectionsFile.read()[groupID.uuidString],
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return selection
    }

    func save(_ selection: FamilyActivitySelection, for groupID: UUID) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        store.selectionsFile.update { $0[groupID.uuidString] = data }
    }

    func all() -> [UUID: FamilyActivitySelection] {
        var result: [UUID: FamilyActivitySelection] = [:]
        for (key, data) in store.selectionsFile.read() {
            if let id = UUID(uuidString: key),
               let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
                result[id] = selection
            }
        }
        return result
    }

    static func isEmpty(_ s: FamilyActivitySelection) -> Bool {
        s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty
    }

    // MARK: Token -> group lookup (used by the shield extensions)

    func groupIDs(containing token: ApplicationToken) -> [UUID] {
        all().filter { $0.value.applicationTokens.contains(token) }.map(\.key)
    }

    func groupIDs(containing token: WebDomainToken) -> [UUID] {
        all().filter { $0.value.webDomainTokens.contains(token) }.map(\.key)
    }

    func groupIDs(containing token: ActivityCategoryToken) -> [UUID] {
        all().filter { $0.value.categoryTokens.contains(token) }.map(\.key)
    }
}
