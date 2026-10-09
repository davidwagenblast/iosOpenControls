import Foundation

/// Everything the child app and its extensions share, stored as JSON files in the
/// App Group container.
final class SharedStore {
    static let shared = SharedStore()

    let directory: URL

    let policyFile: JSONFile<Box<Policy>>
    /// Group ID string -> encoded `FamilyActivitySelection`.
    let selectionsFile: JSONFile<[String: Data]>
    let tallyFile: JSONFile<UsageTally>
    let grantsFile: JSONFile<[StoredGrant]>
    let overridesFile: JSONFile<[ScheduleOverride]>
    let pauseFile: JSONFile<Box<PauseState>>
    let contextFile: JSONFile<Box<ShieldContext>>
    let outboxFile: JSONFile<[OutboxItem]>
    let processedFile: JSONFile<ProcessedState>
    let historyFile: JSONFile<[DailyUsage]>
    let requestsFile: JSONFile<[LocalRequest]>
    let tasksFile: JSONFile<[LocalTaskEntry]>
    let planFile: JSONFile<Box<String>>
    let diagnosticsFile: JSONFile<[String]>

    init(directory: URL? = nil) {
        let base = directory ?? SharedStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base

        func file<V: Codable>(_ name: String, _ fallback: V) -> JSONFile<V> {
            JSONFile(url: base.appendingPathComponent(name + ".json"), defaultValue: fallback)
        }
        policyFile = file("policy", Box<Policy>())
        selectionsFile = file("selections", [:])
        tallyFile = file("tally", UsageTally(dayKey: ""))
        grantsFile = file("grants", [])
        overridesFile = file("overrides", [])
        pauseFile = file("pause", Box<PauseState>())
        contextFile = file("context", Box<ShieldContext>())
        outboxFile = file("outbox", [])
        processedFile = file("processed", ProcessedState())
        historyFile = file("history", [])
        requestsFile = file("requests", [])
        tasksFile = file("tasks", [])
        planFile = file("plan", Box<String>())
        diagnosticsFile = file("diagnostics", [])
    }

    private static func defaultDirectory() -> URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            return container.appendingPathComponent("OpenControls", isDirectory: true)
        }
        // No App Group (unit tests, previews, unsigned simulator builds).
        return FileManager.default.temporaryDirectory.appendingPathComponent("OpenControls", isDirectory: true)
    }

    var policy: Policy? {
        get { policyFile.read().value }
        set { policyFile.write(Box(newValue)) }
    }

    var pause: PauseState? {
        get { pauseFile.read().value }
        set { pauseFile.write(Box(newValue)) }
    }

    var context: ShieldContext? {
        get { contextFile.read().value }
        set { contextFile.write(Box(newValue)) }
    }

    func log(_ message: String) {
        diagnosticsFile.update { lines in
            lines.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
            if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        }
    }
}

/// Snapshot the shield UI extensions read to explain *why* something is blocked.
struct ShieldContext: Codable, Hashable {
    var decision: ShieldDecision
    var askEnabled: Bool
    var askMinutes: Int
    var groupNames: [UUID: String]
    var updatedAt: Date
}
