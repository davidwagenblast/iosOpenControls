import Foundation
import CryptoKit

enum Sender: String, Codable, Hashable {
    case parent, child
}

/// One encrypted message in the shared mailbox.
struct Envelope: Hashable {
    var id: UUID
    var channelID: String
    var sender: Sender
    /// Routing label only (e.g. "request"); the content is in `body`.
    var kind: String
    /// Milliseconds since 1970 on the sender's clock.
    var timestamp: Int64
    /// AES-GCM combined box (nonce + ciphertext + tag).
    var body: Data
    /// Ed25519 signature; present on parent messages.
    var signature: Data?
}

enum EnvelopeError: Error {
    case malformed
    case missingKey
    case badSignature
}

enum EnvelopeCodec {
    /// Authenticated (but not encrypted) header: tampering with routing fields invalidates the message.
    static func header(id: UUID, channelID: String, sender: Sender, kind: String, timestamp: Int64) -> Data {
        Data("\(id.uuidString)|\(channelID)|\(sender.rawValue)|\(kind)|\(timestamp)".utf8)
    }

    static func seal(_ payload: Payload, sender: Sender, keys: ChannelKeys,
                     signer: Curve25519.Signing.PrivateKey?, now: Date = Date()) throws -> Envelope {
        let id = UUID()
        let timestamp = Int64(now.timeIntervalSince1970 * 1000)
        let kind = payload.kind
        let header = header(id: id, channelID: keys.channelID, sender: sender, kind: kind, timestamp: timestamp)
        let plaintext = try JSONCoding.makeEncoder().encode(payload)
        let box = try AES.GCM.seal(plaintext, using: keys.key, authenticating: header)
        guard let combined = box.combined else { throw EnvelopeError.malformed }

        var signature: Data?
        if sender == .parent {
            guard let signer else { throw EnvelopeError.missingKey }
            signature = try signer.signature(for: header + combined)
        }
        return Envelope(id: id, channelID: keys.channelID, sender: sender, kind: kind,
                        timestamp: timestamp, body: combined, signature: signature)
    }

    /// - Parameter parentPublicKey: required for parent-sent envelopes (the child
    ///   always passes it); ignored for child-sent ones.
    static func open(_ envelope: Envelope, keys: ChannelKeys,
                     parentPublicKey: Curve25519.Signing.PublicKey?) throws -> Payload {
        let header = header(id: envelope.id, channelID: envelope.channelID, sender: envelope.sender,
                            kind: envelope.kind, timestamp: envelope.timestamp)
        if envelope.sender == .parent {
            guard let parentPublicKey else { throw EnvelopeError.missingKey }
            guard let signature = envelope.signature,
                  parentPublicKey.isValidSignature(signature, for: header + envelope.body)
            else { throw EnvelopeError.badSignature }
        }
        let box = try AES.GCM.SealedBox(combined: envelope.body)
        let plaintext = try AES.GCM.open(box, using: keys.key, authenticating: header)
        return try JSONCoding.makeDecoder().decode(Payload.self, from: plaintext)
    }
}
