import Foundation
import CryptoKit

/// Salted hash of the parent PIN that unlocks setup on the child's device.
/// This keeps a curious child out of the settings screen; it is not a defence
/// against someone with a jailbroken phone.
struct PinVerifier: Codable, Hashable {
    var salt: Data
    var hash: Data

    static func make(pin: String) -> PinVerifier {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return PinVerifier(salt: salt, hash: digest(salt: salt, pin: pin))
    }

    func verify(_ pin: String) -> Bool {
        PinVerifier.digest(salt: salt, pin: pin) == hash
    }

    private static func digest(salt: Data, pin: String) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}
