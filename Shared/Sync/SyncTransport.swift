import Foundation

/// A push subscription the transport should maintain.
struct SubscriptionSpec: Hashable {
    var id: String
    /// Only fire for this message kind (nil = any kind).
    var kind: String?
    /// Visible alert text; nil = silent background push.
    var alert: String?
}

protocol SyncTransport {
    func send(_ envelope: Envelope) async throws
    /// Envelopes from `sender` on `channelID` with `timestamp > after`, oldest first.
    func fetch(channelID: String, from sender: Sender, after timestamp: Int64) async throws -> [Envelope]
    func subscribe(channelID: String, to sender: Sender, specs: [SubscriptionSpec]) async throws
    /// Best-effort cleanup of messages this device sent before `cutoff`.
    func prune(channelID: String, sentBy sender: Sender, before cutoff: Int64) async
}

/// In-memory mailbox for previews and tests.
final class MemoryTransport: SyncTransport {
    static let shared = MemoryTransport()

    private let lock = NSLock()
    private var envelopes: [Envelope] = []

    // Locking lives in synchronous helpers: NSLock must not be held across an `await`.
    private func append(_ envelope: Envelope) {
        lock.lock(); defer { lock.unlock() }
        envelopes.append(envelope)
    }

    private func matching(channelID: String, from sender: Sender, after timestamp: Int64) -> [Envelope] {
        lock.lock(); defer { lock.unlock() }
        return envelopes
            .filter { $0.channelID == channelID && $0.sender == sender && $0.timestamp > timestamp }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func remove(channelID: String, sentBy sender: Sender, before cutoff: Int64) {
        lock.lock(); defer { lock.unlock() }
        envelopes.removeAll { $0.channelID == channelID && $0.sender == sender && $0.timestamp < cutoff }
    }

    func send(_ envelope: Envelope) async throws {
        append(envelope)
    }

    func fetch(channelID: String, from sender: Sender, after timestamp: Int64) async throws -> [Envelope] {
        matching(channelID: channelID, from: sender, after: timestamp)
    }

    func subscribe(channelID: String, to sender: Sender, specs: [SubscriptionSpec]) async throws {}

    func prune(channelID: String, sentBy sender: Sender, before cutoff: Int64) async {
        remove(channelID: channelID, sentBy: sender, before: cutoff)
    }
}
