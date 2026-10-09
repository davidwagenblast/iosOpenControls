import Foundation
import CryptoKit

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}

/// What the parent hands to the child (as a link or QR code) to pair the two apps.
///
/// - `secret` is a random 32-byte value both sides derive the channel ID and the
///   encryption key from. It never touches CloudKit.
/// - `parentPublicKey` lets the child verify that parent messages are genuine: the
///   matching private key stays on the parent's devices, so the child (who knows
///   `secret`) still cannot forge a grant.
struct PairingInvite: Codable, Hashable {
    var version: Int
    var secret: Data
    var parentPublicKey: Data
    var childName: String

    static func create(childName: String, parentPublicKey: Data) -> PairingInvite {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return PairingInvite(version: 1, secret: secret, parentPublicKey: parentPublicKey, childName: childName)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = AppConfig.kidURLScheme
        components.host = "pair"
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        components.queryItems = [URLQueryItem(name: "i", value: json.base64URLEncodedString())]
        return components.url ?? URL(string: "\(AppConfig.kidURLScheme)://pair")!
    }

    /// Accepts the full link, or just the base64url token after `i=`.
    static func parse(_ text: String) -> PairingInvite? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var token = trimmed
        if let components = URLComponents(string: trimmed),
           let value = components.queryItems?.first(where: { $0.name == "i" })?.value {
            token = value
        }
        guard let data = Data(base64URLEncoded: token),
              let invite = try? JSONDecoder().decode(PairingInvite.self, from: data),
              invite.version == 1, invite.secret.count == 32, invite.parentPublicKey.count == 32
        else { return nil }
        return invite
    }
}

/// Channel ID + encryption key derived from the pairing secret.
struct ChannelKeys {
    let channelID: String
    let key: SymmetricKey

    init(secret: Data) {
        let input = SymmetricKey(data: secret)
        let salt = Data("OpenControls.v1".utf8)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("enc".utf8), outputByteCount: 32)
        let channel = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("channel".utf8), outputByteCount: 16)
        channelID = channel.withUnsafeBytes { raw in raw.map { String(format: "%02x", $0) }.joined() }
    }
}
