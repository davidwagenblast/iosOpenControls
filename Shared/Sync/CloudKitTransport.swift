import Foundation
import CloudKit

/// Mailbox in the container's **public** CloudKit database.
///
/// Why public: the parent and child are usually different iCloud accounts, and a
/// shared private zone needs a CKShare hand-off. Here the channel ID is an
/// unguessable value derived from a secret only the two apps know, and every body is
/// AES-GCM encrypted (parent messages also signed), so the server only ever sees
/// opaque blobs under a random name.
///
/// Schema (create in the CloudKit Dashboard, record type `Envelope`):
/// `channel` String (queryable), `sender` String (queryable), `kind` String
/// (queryable), `ts` Int64 (queryable, sortable), `body` Bytes, `sig` Bytes.
final class CloudKitTransport: SyncTransport {
    static let recordType = "Envelope"

    private let database: CKDatabase

    init(containerIdentifier: String = AppConfig.cloudKitContainerIdentifier) {
        database = CKContainer(identifier: containerIdentifier).publicCloudDatabase
    }

    func send(_ envelope: Envelope) async throws {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: envelope.id.uuidString))
        record["channel"] = envelope.channelID
        record["sender"] = envelope.sender.rawValue
        record["kind"] = envelope.kind
        record["ts"] = envelope.timestamp
        record["body"] = envelope.body
        if let signature = envelope.signature { record["sig"] = signature }
        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already uploaded by an earlier attempt that we didn't hear back from.
        }
    }

    func fetch(channelID: String, from sender: Sender, after timestamp: Int64) async throws -> [Envelope] {
        let predicate = NSPredicate(format: "channel == %@ AND sender == %@ AND ts > %lld",
                                    channelID, sender.rawValue, timestamp)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "ts", ascending: true)]

        var results: [Envelope] = []
        var page = try await database.records(matching: query, resultsLimit: 100)
        while true {
            for (_, result) in page.matchResults {
                if case .success(let record) = result, let envelope = Self.envelope(from: record) {
                    results.append(envelope)
                }
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 100)
        }
        return results
    }

    func subscribe(channelID: String, to sender: Sender, specs: [SubscriptionSpec]) async throws {
        for spec in specs {
            let predicate: NSPredicate
            if let kind = spec.kind {
                predicate = NSPredicate(format: "channel == %@ AND sender == %@ AND kind == %@",
                                        channelID, sender.rawValue, kind)
            } else {
                predicate = NSPredicate(format: "channel == %@ AND sender == %@", channelID, sender.rawValue)
            }
            let subscription = CKQuerySubscription(recordType: Self.recordType, predicate: predicate,
                                                   subscriptionID: spec.id, options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            if let alert = spec.alert {
                info.alertBody = alert
                info.soundName = "default"
            }
            subscription.notificationInfo = info
            do {
                _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            } catch {
                // Re-saving an identical subscription can be rejected; the existing one keeps working.
            }
        }
    }

    func prune(channelID: String, sentBy sender: Sender, before cutoff: Int64) async {
        let predicate = NSPredicate(format: "channel == %@ AND sender == %@ AND ts < %lld",
                                    channelID, sender.rawValue, cutoff)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        guard let page = try? await database.records(matching: query, resultsLimit: 100) else { return }
        let ids = page.matchResults.map { $0.0 }
        guard !ids.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
    }

    private static func envelope(from record: CKRecord) -> Envelope? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let channel = record["channel"] as? String,
              let senderRaw = record["sender"] as? String, let sender = Sender(rawValue: senderRaw),
              let kind = record["kind"] as? String,
              let timestamp = record["ts"] as? Int64,
              let body = record["body"] as? Data
        else { return nil }
        return Envelope(id: id, channelID: channel, sender: sender, kind: kind,
                        timestamp: timestamp, body: body, signature: record["sig"] as? Data)
    }
}
