import Foundation
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

@Suite("TempoSettledChargeMethod")
struct TempoSettledChargeMethodTests {
    private static let chainId: UInt64 = 1
    private static let challengeId = "charge-123"
    private static let realm = "https://api.example.com"
    private static let payerAddress = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let currency = "0x20C0000000000000000000000000000000000001"
    private static let recipient = "0x1111111111111111111111111111111111111111"
    private static let clock = Date(timeIntervalSince1970: 1_767_312_000)

    private func payerKey() -> Data {
        Data([UInt8](repeating: 0, count: 31) + [1])
    }

    private func method(
        builder: any TempoTransferTxBuilder,
        broadcaster: (any TempoTransferBroadcaster)? = nil,
        clientId: String? = nil,
        approval: TempoApprovalPolicy = .allowAll,
        now: @escaping @Sendable () -> Date = { clock }
    ) throws -> TempoSettledChargeMethod {
        try #require(TempoSettledChargeMethod(
            payerPrivateKey: payerKey(),
            transferBuilder: builder,
            broadcaster: broadcaster,
            clientId: clientId,
            defaultChainId: Self.chainId,
            approval: approval,
            now: now
        ))
    }

    /// A `tempo` / `charge` challenge with `amount`, `recipient`, `currency`, and optional
    /// `methodDetails` (chainId / supportedModes / memo) and `expires`.
    private func chargeChallenge(
        amount: String = "1000000",
        recipient: String? = Self.recipient,
        currency: String? = Self.currency,
        supportedModes: [String]? = nil,
        memo: String? = nil,
        intent: String = "charge",
        expires: Expires? = nil
    ) throws -> Challenge {
        var members: [String: JSONValue] = ["amount": .string(amount)]
        if let recipient { members["recipient"] = .string(recipient) }
        if let currency { members["currency"] = .string(currency) }
        var details: [String: JSONValue] = ["chainId": .integer(Int64(Self.chainId))]
        if let supportedModes {
            details["supportedModes"] = .array(supportedModes.map(JSONValue.string))
        }
        if let memo { details["memo"] = .string(memo) }
        members["methodDetails"] = .object(details)
        return try Challenge(
            id: Self.challengeId, realm: Self.realm,
            method: MethodName("tempo"), intent: IntentName(intent),
            request: EncodedJSON(json: .object(members)), expires: expires
        )
    }

    // MARK: supports

    @Test("supports a non-zero charge with recipient + currency and pull allowed")
    func supportsValidCharge() throws {
        let subject = try method(builder: StubTransferBuilder())
        #expect(try subject.supports(chargeChallenge()))
        #expect(try subject.supports(chargeChallenge(supportedModes: ["pull", "push"])))
        #expect(try subject
            .supports(chargeChallenge(amount: "0")) == false) // zero is the proof path
        #expect(try subject.supports(chargeChallenge(recipient: nil)) == false)
        #expect(try subject.supports(chargeChallenge(currency: nil)) == false)
        // present but not a valid address -> unsupported (supports() agrees with buildCredential)
        #expect(try subject.supports(chargeChallenge(currency: "not-an-address")) == false)
        #expect(try subject.supports(chargeChallenge(recipient: "0x1234")) == false)
        #expect(try subject.supports(chargeChallenge(supportedModes: ["push"])) == false)
        #expect(try subject.supports(chargeChallenge(intent: "session")) == false)
    }

    // MARK: credential content

    @Test("builds the transaction credential: payload, source, and the built tx")
    func buildsTransactionCredential() async throws {
        let builder = StubTransferBuilder()
        let credential = try await method(builder: builder).buildCredential(for: chargeChallenge())
        #expect(credential.payload["type"] == .string("transaction"))
        #expect(credential.payload["signature"] == .string(builtTx.hexPrefixed))
        #expect(credential.source == "did:pkh:eip155:1:\(Self.payerAddress)")
        #expect(credential.challenge.id == Self.challengeId)

        let captured = try #require(builder.captured)
        #expect(captured.amount == "1000000")
        #expect(captured.currency.bytes == EthereumAddress(hex: Self.currency)?.bytes)
        #expect(captured.recipient.bytes == EthereumAddress(hex: Self.recipient)?.bytes)
        #expect(captured.payer.bytes == EthereumAddress(hex: Self.payerAddress)?.bytes)
    }

    @Test("derives the attribution memo from realm + challenge when the server pins none")
    func derivesAttributionMemo() async throws {
        let builder = StubTransferBuilder()
        _ = try await method(builder: builder, clientId: "my-app").buildCredential(
            for: chargeChallenge()
        )
        let expected = Attribution.encode(
            serverId: Self.realm, challengeId: Self.challengeId, clientId: "my-app"
        )
        #expect(try #require(builder.captured).memo == expected)
    }

    @Test("uses the server-pinned memo when present")
    func usesPinnedMemo() async throws {
        let builder = StubTransferBuilder()
        let pinned = Data(repeating: 0xCD, count: 32)
        _ = try await method(builder: builder).buildCredential(
            for: chargeChallenge(memo: pinned.hexPrefixed)
        )
        #expect(try #require(builder.captured).memo == pinned)
    }

    @Test("validBefore is now + window, capped at the challenge expiry")
    func validBeforeWindowAndCap() async throws {
        // No expiry -> now + 25s.
        let builder = StubTransferBuilder()
        _ = try await method(builder: builder).buildCredential(for: chargeChallenge())
        let base = UInt64(Self.clock.timeIntervalSince1970)
        #expect(try #require(builder.captured).validBefore == base + 25)

        // A near expiry (now + 10s) caps the window.
        let capped = StubTransferBuilder()
        let nearExpiry = try Expires(date: Self.clock.addingTimeInterval(10))
        _ = try await method(builder: capped).buildCredential(
            for: chargeChallenge(expires: nearExpiry)
        )
        #expect(try #require(capped.captured).validBefore == base + 10)
    }

    // MARK: rejections

    @Test("a push-only challenge is rejected when no broadcaster is configured")
    func rejectsPushOnly() async throws {
        await #expect(throws: TempoSettledChargeError.self) {
            _ = try await method(builder: StubTransferBuilder()).buildCredential(
                for: chargeChallenge(supportedModes: ["push"])
            )
        }
    }

    @Test("a zero-amount charge is rejected (that is the proof path)")
    func rejectsZeroAmount() async throws {
        await #expect(throws: TempoSettledChargeError.self) {
            _ = try await method(builder: StubTransferBuilder()).buildCredential(
                for: chargeChallenge(amount: "0")
            )
        }
    }

    @Test("a denied approval produces no credential")
    func rejectsDeniedApproval() async throws {
        await #expect(throws: TempoSettledChargeError.self) {
            _ = try await method(builder: StubTransferBuilder(), approval: .deny)
                .buildCredential(for: chargeChallenge())
        }
    }

    @Test("a malformed server-pinned memo is rejected (fail closed)")
    func rejectsInvalidPinnedMemo() async throws {
        // Not hex.
        await #expect(throws: TempoSettledChargeError.invalidMemo) {
            _ = try await method(builder: StubTransferBuilder())
                .buildCredential(for: chargeChallenge(memo: "0xnothex"))
        }
        // Valid hex, wrong length (16 bytes, not 32).
        await #expect(throws: TempoSettledChargeError.invalidMemo) {
            _ = try await method(builder: StubTransferBuilder())
                .buildCredential(for: chargeChallenge(memo: "0x" + String(
                    repeating: "ab",
                    count: 16
                )))
        }
    }

    @Test("advertises exactly the tempo/charge payment range")
    func advertisesChargeRange() throws {
        let ranges = try method(builder: StubTransferBuilder()).paymentRanges
        #expect(ranges.count == 1)
        #expect(ranges.first?.method == .value(TempoMethod.name))
        #expect(ranges.first?.intent == .value(.charge))
    }

    // MARK: push mode

    @Test("push mode broadcasts a sequential-nonce tx and emits the hash credential")
    func pushModeEmitsHashCredential() async throws {
        let builder = StubTransferBuilder()
        let broadcaster = StubBroadcaster(hash: "0xabc123")
        let subject = try method(builder: builder, broadcaster: broadcaster)
        let credential = try await subject
            .buildCredential(for: chargeChallenge(supportedModes: ["push"]))
        #expect(credential.payload["type"] == .string("hash"))
        #expect(credential.payload["hash"] == .string("0xabc123"))
        // Push is a sequential-nonce tx (validBefore nil), and the broadcaster got the built tx.
        #expect(try #require(builder.captured).validBefore == nil)
        #expect(broadcaster.broadcasted == builtTx)
    }

    @Test("with a broadcaster, pull is still preferred when the server allows both")
    func prefersPullWhenBothOffered() async throws {
        let builder = StubTransferBuilder()
        let subject = try method(builder: builder, broadcaster: StubBroadcaster(hash: "0xabc"))
        let credential = try await subject.buildCredential(
            for: chargeChallenge(supportedModes: ["pull", "push"])
        )
        #expect(credential.payload["type"] == .string("transaction"))
        #expect(try #require(builder.captured).validBefore != nil) // pull -> expiring nonce
    }

    @Test("push-only is supported once a broadcaster is configured")
    func pushOnlySupportedWithBroadcaster() throws {
        let subject = try method(
            builder: StubTransferBuilder(),
            broadcaster: StubBroadcaster(hash: "0x1")
        )
        #expect(try subject.supports(chargeChallenge(supportedModes: ["push"])))
    }

    @Test("a reverted/failed broadcast surfaces as broadcastFailed, not a hash credential")
    func broadcastFailureThrows() async throws {
        let subject = try method(builder: StubTransferBuilder(), broadcaster: FailingBroadcaster())
        await #expect(throws: TempoSettledChargeError.self) {
            _ = try await subject.buildCredential(for: chargeChallenge(supportedModes: ["push"]))
        }
    }
}

/// The fixed "signed tx" the stub builder returns; the credential carries its 0x-hex.
private let builtTx = Data([0x76, 0x01, 0x02, 0x03])

/// A stub ``TempoTransferTxBuilder`` that records the parameters it was handed and returns a fixed
/// signed transaction, so the method's routing/assembly can be asserted without the FFI.
private final class StubTransferBuilder: TempoTransferTxBuilder, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TempoTransferParameters?
    var captured: TempoTransferParameters? {
        lock.withLock { stored }
    }

    func buildTransferTransaction(
        _ parameters: TempoTransferParameters,
        chainID _: UInt64
    ) async throws -> Data {
        lock.withLock { stored = parameters }
        return builtTx
    }
}

/// A stub ``TempoTransferBroadcaster`` that records the raw tx it was handed and returns a fixed
/// hash, so push-mode credential assembly can be asserted without a chain.
private final class StubBroadcaster: TempoTransferBroadcaster, @unchecked Sendable {
    private let hash: String
    private let lock = NSLock()
    private var raw: Data?
    var broadcasted: Data? {
        lock.withLock { raw }
    }

    init(hash: String) {
        self.hash = hash
    }

    func broadcast(_ rawTransaction: Data) async throws -> String {
        lock.withLock { raw = rawTransaction }
        return hash
    }
}

/// A stub broadcaster that always fails, to exercise the push-mode error path.
private struct FailingBroadcaster: TempoTransferBroadcaster {
    func broadcast(_: Data) async throws -> String {
        throw TempoBroadcastError.reverted("0xreverted")
    }
}
