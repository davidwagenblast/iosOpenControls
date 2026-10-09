import XCTest
import CryptoKit

final class SyncTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func makePair() -> (Curve25519.Signing.PrivateKey, PairingInvite, ChannelKeys) {
        let signer = Curve25519.Signing.PrivateKey()
        let invite = PairingInvite.create(childName: "Sam", parentPublicKey: signer.publicKey.rawRepresentation)
        return (signer, invite, ChannelKeys(secret: invite.secret))
    }

    func testInviteSurvivesTheLink() {
        let (_, invite, _) = makePair()
        XCTAssertEqual(PairingInvite.parse(invite.url.absoluteString), invite)
        XCTAssertEqual(invite.url.scheme, AppConfig.kidURLScheme)
        // Also accepts the bare token pasted from a message.
        let token = invite.url.absoluteString.components(separatedBy: "i=").last!
        XCTAssertEqual(PairingInvite.parse(token), invite)
        XCTAssertNil(PairingInvite.parse("not an invite"))
    }

    func testChannelKeysAreDeterministicAndSecretDependent() {
        let (_, invite, keys) = makePair()
        XCTAssertEqual(ChannelKeys(secret: invite.secret).channelID, keys.channelID)
        XCTAssertEqual(keys.channelID.count, 32)
        let other = ChannelKeys(secret: Data(repeating: 7, count: 32))
        XCTAssertNotEqual(other.channelID, keys.channelID)
    }

    func testParentMessageRoundTrip() throws {
        let (signer, _, keys) = makePair()
        let grant = Grant(groupID: UUID(), minutes: 15, issuedAt: fixedDate, source: .parentBonus, note: "Good job")
        let envelope = try EnvelopeCodec.seal(.grant(grant), sender: .parent, keys: keys, signer: signer, now: fixedDate)
        XCTAssertEqual(envelope.kind, "grant")
        XCTAssertNotNil(envelope.signature)
        let opened = try EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: signer.publicKey)
        XCTAssertEqual(opened, .grant(grant))
    }

    func testChildMessageRoundTripWithoutSignature() throws {
        let (_, _, keys) = makePair()
        let request = ChildRequest(id: UUID(), createdAt: fixedDate, kind: .moreTime(groupID: UUID()), requestedMinutes: 15)
        let envelope = try EnvelopeCodec.seal(.request(request), sender: .child, keys: keys, signer: nil, now: fixedDate)
        XCTAssertNil(envelope.signature)
        XCTAssertEqual(try EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: nil), .request(request))
    }

    func testChildCannotForgeParentMessages() throws {
        let (parentKey, _, keys) = makePair()
        let forger = Curve25519.Signing.PrivateKey() // the child knows the channel secret but not the parent's key
        let grant = Grant(groupID: UUID(), minutes: 999, issuedAt: fixedDate, source: .parentBonus)
        let forged = try EnvelopeCodec.seal(.grant(grant), sender: .parent, keys: keys, signer: forger, now: fixedDate)
        XCTAssertThrowsError(try EnvelopeCodec.open(forged, keys: keys, parentPublicKey: parentKey.publicKey)) {
            XCTAssertEqual($0 as? EnvelopeError, .badSignature)
        }
        var unsigned = forged
        unsigned.signature = nil
        XCTAssertThrowsError(try EnvelopeCodec.open(unsigned, keys: keys, parentPublicKey: parentKey.publicKey))
    }

    func testTamperingWithRoutingFieldsIsDetected() throws {
        let (signer, _, keys) = makePair()
        var envelope = try EnvelopeCodec.seal(.pause(nil), sender: .parent, keys: keys, signer: signer, now: fixedDate)
        envelope.kind = "policy"
        XCTAssertThrowsError(try EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: signer.publicKey))

        var child = try EnvelopeCodec.seal(.request(ChildRequest(kind: .endPause, requestedMinutes: 15)),
                                           sender: .child, keys: keys, signer: nil, now: fixedDate)
        child.timestamp += 1
        XCTAssertThrowsError(try EnvelopeCodec.open(child, keys: keys, parentPublicKey: nil))
    }

    func testWrongChannelKeyCannotRead() throws {
        let (signer, _, keys) = makePair()
        let other = ChannelKeys(secret: Data(repeating: 1, count: 32))
        let envelope = try EnvelopeCodec.seal(.pause(nil), sender: .parent, keys: keys, signer: signer)
        XCTAssertThrowsError(try EnvelopeCodec.open(envelope, keys: other, parentPublicKey: signer.publicKey))
    }

    func testPolicyRoundTripsThroughJSON() throws {
        var policy = Policy.starter(childName: "Sam")
        policy.pin = PinVerifier.make(pin: "1234")
        let (signer, _, keys) = makePair()
        let envelope = try EnvelopeCodec.seal(.policy(policy), sender: .parent, keys: keys, signer: signer)
        guard case .policy(let decoded) = try EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: signer.publicKey) else {
            return XCTFail("expected a policy")
        }
        XCTAssertEqual(decoded.groups, policy.groups)
        XCTAssertEqual(decoded.schedules, policy.schedules)
        XCTAssertEqual(decoded.tasks, policy.tasks)
        XCTAssertEqual(decoded.pin, policy.pin)
    }

    func testStatusWithUUIDKeyedDictionariesRoundTrips() throws {
        let (_, _, keys) = makePair()
        let id = UUID()
        let status = ChildStatus(sentAt: fixedDate, dayKey: "2025-01-06", authorization: .approved, isTestMode: false,
                                 policyVersion: 3, usageToday: [id: 42], shieldedGroupIDs: [id], modeSummary: "Bedtime",
                                 groupsMissingApps: [], history: [DailyUsage(dayKey: "2025-01-05", minutes: [id: 80])],
                                 problems: [])
        let envelope = try EnvelopeCodec.seal(.status(status), sender: .child, keys: keys, signer: nil)
        XCTAssertEqual(envelope.kind, "status")
        XCTAssertEqual(try EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: nil), .status(status))
    }

    func testStatusWithAProblemIsRoutedAsAnAlert() {
        var status = ChildStatus(sentAt: fixedDate, dayKey: "d", authorization: .approved, isTestMode: false, policyVersion: 1,
                                 usageToday: [:], shieldedGroupIDs: [], modeSummary: nil, groupsMissingApps: [], history: [], problems: [])
        XCTAssertEqual(Payload.status(status).kind, "status")
        status.authorization = .denied
        XCTAssertEqual(Payload.status(status).kind, "alert")
    }

    func testMemoryTransportDeliversOnlyNewMessagesFromTheOtherSide() async throws {
        let (signer, _, keys) = makePair()
        let transport = MemoryTransport()
        let first = try EnvelopeCodec.seal(.pause(nil), sender: .parent, keys: keys, signer: signer, now: fixedDate)
        let second = try EnvelopeCodec.seal(.pause(nil), sender: .parent, keys: keys, signer: signer, now: fixedDate.addingTimeInterval(10))
        let mine = try EnvelopeCodec.seal(.request(ChildRequest(kind: .endPause, requestedMinutes: 15)), sender: .child, keys: keys, signer: nil)
        for e in [second, first, mine] { try await transport.send(e) }

        let all = try await transport.fetch(channelID: keys.channelID, from: .parent, after: 0)
        XCTAssertEqual(all.map(\.id), [first.id, second.id], "oldest first, parent messages only")
        let newer = try await transport.fetch(channelID: keys.channelID, from: .parent, after: first.timestamp)
        XCTAssertEqual(newer.map(\.id), [second.id])
        let otherChannel = try await transport.fetch(channelID: "nope", from: .parent, after: 0)
        XCTAssertTrue(otherChannel.isEmpty)
    }

    func testPinVerifier() {
        let pin = PinVerifier.make(pin: "4821")
        XCTAssertTrue(pin.verify("4821"))
        XCTAssertFalse(pin.verify("4822"))
        XCTAssertNotEqual(PinVerifier.make(pin: "4821").hash, pin.hash, "salted")
    }
}
