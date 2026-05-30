import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// TempoChannelMethod is the client side of a tempo/session 402: the first charge to a
// (payee, token, escrow) opens a channel (a signed open tx + an initial voucher), and
// each later charge vouchers against the open channel. These tests are hermetic: a stub
// open-tx builder stands in for the FFI (recording the params it was handed) and the
// salt is fixed, so the channel id and the voucher signature are byte-checkable, and the
// emitted payloads are asserted to match exactly what the server's SessionMethod parses.
@Suite("TempoChannelMethod")
struct TempoChannelMethodTests {
    // MARK: supports() matrix

    @Test("supports a tempo/session challenge naming escrow, recipient, and currency")
    func supportsSession() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(try method.supports(sessionChallenge()))
    }

    @Test("does not support a tempo/charge challenge (that is the proof method's job)")
    func rejectsChargeIntent() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(try method.supports(sessionChallenge(intent: "charge")) == false)
    }

    @Test("does not support a different method, or a missing escrow/recipient/currency")
    func rejectsWrongMethodOrMissingFields() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(try method.supports(sessionChallenge(method: "stripe")) == false)
        #expect(try method.supports(sessionChallenge(escrow: nil)) == false)
        #expect(try method.supports(sessionChallenge(recipient: nil)) == false)
        #expect(try method.supports(sessionChallenge(currency: nil)) == false)
    }

    @Test("does not support a malformed request")
    func rejectsMalformed() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let challenge = try sessionChallenge(requestOverride: EncodedJSON("@@@not-base64@@@"))
        #expect(method.supports(challenge) == false)
    }

    @Test("advertises the tempo/session range, formatting to a header value")
    func advertises() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(AcceptPayment.format(method.paymentRanges) == "tempo/session")
    }

    // MARK: open (first charge)

    @Test("the first charge opens: payload, channel id, deposit, and a verifying voucher")
    func firstChargeOpens() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let credential = try await method.buildCredential(for: sessionChallenge(amount: "100"))

        #expect(credential.payload["action"] == .string("open"))
        #expect(credential.payload["type"] == .string("transaction"))
        #expect(credential.payload["cumulativeAmount"] == .string("100"))
        #expect(credential.payload["transaction"] == .string(Fixture.txBytes.hexPrefixed))
        #expect(credential.payload["authorizedSigner"] == .string(method.address.checksummed))
        #expect(credential.source == ProofSource.did(
            address: method.address,
            chainId: Fixture.chainId
        ))

        let expectedID = try expectedChannelID(payeeHex: Fixture.payeeHex, wallet: method.address)
        #expect(credential.payload["channelId"] == .string(expectedID.hexPrefixed))

        // The voucher recovers to the wallet (byte-real, not merely well-formed).
        #expect(try voucherVerifies(credential.payload, wallet: method.address))

        // The deposit comes from the policy, never the charge amount; the builder ran once.
        let calls = await builder.parameters
        #expect(calls.count == 1)
        #expect(calls.first?.deposit == Fixture.deposit)
        #expect(calls.first?.deposit != "100")
    }

    @Test("the deposit policy sees the suggestedDeposit and its result is used")
    func depositPolicyUsesSuggested() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(
            depositPolicy: { context in context.suggestedDeposit }, builder: builder
        )
        _ = try await method.buildCredential(for: sessionChallenge(suggestedDeposit: "5000"))
        let calls = await builder.parameters
        #expect(calls.first?.deposit == "5000")
    }

    @Test("a nil deposit policy result rejects the open with noDeposit")
    func noDepositRejectsOpen() async throws {
        let method = try makeMethod(depositPolicy: { _ in nil }, builder: StubOpenTxBuilder())
        await #expect(throws: TempoChannelMethodError.noDeposit) {
            _ = try await method.buildCredential(for: sessionChallenge())
        }
    }

    @Test("a failing open builder surfaces openTransactionFailed")
    func openBuilderFailureSurfaces() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder(failure: StubError.boom))
        await #expect(throws: TempoChannelMethodError.self) {
            _ = try await method.buildCredential(for: sessionChallenge())
        }
    }

    // MARK: voucher (subsequent charges)

    @Test("a second charge to the same recipient vouchers, accumulating, without re-opening")
    func secondChargeVouchers() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let first = try await method.buildCredential(for: sessionChallenge(amount: "100"))
        let second = try await method.buildCredential(for: sessionChallenge(amount: "200"))

        #expect(second.payload["action"] == .string("voucher"))
        #expect(second.payload["cumulativeAmount"] == .string("300"))
        #expect(second.payload["transaction"] == nil)
        // A voucher action carries no transaction tag (parity: only open/topUp are typed).
        #expect(second.payload["type"] == nil)
        // Same channel as the open, and the cumulative voucher still verifies.
        #expect(second.payload["channelId"] == first.payload["channelId"])
        #expect(try voucherVerifies(second.payload, wallet: method.address))
        #expect(await builder.parameters.count == 1)
    }

    @Test("a charge to a different recipient opens a second, distinct channel")
    func differentRecipientOpensAgain() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let first = try await method
            .buildCredential(for: sessionChallenge(recipient: Fixture.payeeHex))
        let second = try await method
            .buildCredential(for: sessionChallenge(recipient: Fixture.payee2Hex))

        #expect(first.payload["action"] == .string("open"))
        #expect(second.payload["action"] == .string("open"))
        #expect(first.payload["channelId"] != second.payload["channelId"])
        #expect(await builder.parameters.count == 2)
    }

    // MARK: amount + cumulative edges

    @Test("an amount that does not fit uint128 throws amountExceedsChannelRange")
    func amountTooLarge() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        // 2^128, one past the channel uint128 max.
        let over = "340282366920938463463374607431768211456"
        await #expect(throws: TempoChannelMethodError.amountExceedsChannelRange) {
            _ = try await method.buildCredential(for: sessionChallenge(amount: over))
        }
    }

    @Test("a cumulative that would overflow uint128 throws cumulativeOverflow")
    func cumulativeOverflows() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let max = "340282366920938463463374607431768211455" // 2^128 - 1
        _ = try await method.buildCredential(for: sessionChallenge(amount: max))
        await #expect(throws: TempoChannelMethodError.cumulativeOverflow) {
            _ = try await method.buildCredential(for: sessionChallenge(amount: "1"))
        }
    }

    // MARK: approval + direct misuse

    @Test("a denying policy produces no credential and does not open")
    func approvalDenied() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(approval: .deny, builder: builder)
        await #expect(throws: TempoChannelMethodError.approvalDenied) {
            _ = try await method.buildCredential(for: sessionChallenge())
        }
        #expect(await builder.parameters.isEmpty)
    }

    @Test("buildCredential refuses a wrong method/intent even when called directly")
    func refusesWrongMethodIntent() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        await #expect(throws: TempoChannelMethodError.wrongMethodOrIntent) {
            _ = try await method.buildCredential(for: sessionChallenge(intent: "charge"))
        }
    }

    // MARK: concurrency

    @Test("concurrent first charges to one key open exactly one channel")
    func concurrentOpensOnce() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let challenge = try sessionChallenge(amount: "10")
        let actions = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    let credential = try await method.buildCredential(for: challenge)
                    return try #require(credential.payload["action"]?.stringValue)
                }
            }
            var collected: [String] = []
            for try await action in group {
                collected.append(action)
            }
            return collected
        }
        #expect(actions.count(where: { $0 == "open" }) == 1)
        #expect(actions.count(where: { $0 == "voucher" }) == 11)
        #expect(await builder.parameters.count == 1)
    }

    // MARK: end-to-end through PaymentClient

    @Test("end-to-end: a 402 session is paid and the retry carries the open credential")
    func endToEnd() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let challenge = try sessionChallenge(amount: "100")
        let transport = RecordingTransport(challengeHeader: challenge.headerValue)
        let client = PaymentClient(transport: transport, methods: [method])
        let request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/paid"
        )

        let (response, body) = try await client.send(request)
        #expect(response.status.code == 200)
        #expect(body == Data("paid".utf8))

        let sent = await transport.sent
        #expect(sent.count == 2)
        let auth = try #require(sent[1].request.headerFields[.authorization])
        #expect(auth.hasPrefix("Payment "))
        let credential = try Credential(headerValue: auth)
        #expect(credential.payload["action"] == .string("open"))
        #expect(try voucherVerifies(credential.payload, wallet: method.address))
    }
}

// MARK: - test support

/// Fixed inputs. The signing key is `0x..01` (the shared proof vector key), so the wallet
/// is `0x7E5F...Bdf`. Addresses have no letters that EIP-55 would re-case, so the literals
/// are also their checksummed form.
private enum Fixture {
    static let chainId: UInt64 = 1
    static let key = Data([UInt8](repeating: 0, count: 31) + [1])
    static let escrowHex = "0x000000000000000000000000000000000000eeee"
    static let payeeHex = "0x1111111111111111111111111111111111111111"
    static let payee2Hex = "0x2222222222222222222222222222222222222222"
    static let tokenHex = "0x000000000000000000000000000000000000abcd"
    static let deposit = "1000000"
    static let salt = Data(repeating: 0xAB, count: 32)
    static let txBytes = Data([0x76, 0x01, 0x02, 0x03])
}

private enum StubError: Error { case boom }

/// A ``TempoOpenTxBuilder`` that returns canned bytes (or fails) and records the
/// parameters it was handed, so a test can assert how many opens ran and with what
/// deposit.
private actor StubOpenTxBuilder: TempoOpenTxBuilder {
    private let transaction: Data
    private let failure: (any Error)?
    private(set) var parameters: [TempoOpenParameters] = []

    init(transaction: Data = Fixture.txBytes, failure: (any Error)? = nil) {
        self.transaction = transaction
        self.failure = failure
    }

    func buildOpenTransaction(
        _ parameters: TempoOpenParameters,
        chainID _: UInt64
    ) async throws -> Data {
        self.parameters.append(parameters)
        if let failure { throw failure }
        return transaction
    }
}

/// Records sent requests; answers the first with a 402 carrying the challenge and the
/// paid retry with a 200.
private actor RecordingTransport: MPPHTTPTransport {
    private(set) var sent: [(request: HTTPRequest, body: Data)] = []
    private let challengeHeader: String

    init(challengeHeader: String) {
        self.challengeHeader = challengeHeader
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        sent.append((request, body))
        if sent.count == 1 {
            var response = HTTPResponse(status: .init(code: 402))
            response.headerFields[.wwwAuthenticate] = challengeHeader
            return (response, Data())
        }
        return (HTTPResponse(status: .ok), Data("paid".utf8))
    }
}

private func makeSigner() throws -> Secp256k1Signer {
    try Secp256k1Signer(privateKey: Fixture.key)
}

private func makeMethod(
    depositPolicy: @escaping @Sendable (DepositContext) -> String? = { _ in Fixture.deposit },
    approval: TempoApprovalPolicy = .allowAll,
    builder: StubOpenTxBuilder
) throws -> TempoChannelMethod {
    let method = try TempoChannelMethod(
        signer: makeSigner(),
        openBuilder: builder,
        defaultChainId: Fixture.chainId,
        depositPolicy: depositPolicy,
        approval: approval,
        saltProvider: { Fixture.salt }
    )
    return try #require(method)
}

/// A tempo/session challenge whose request carries the charge amount and the
/// `methodDetails` the client resolves the channel from.
private func sessionChallenge(
    amount: String = "100",
    recipient: String? = Fixture.payeeHex,
    currency: String? = Fixture.tokenHex,
    escrow: String? = Fixture.escrowHex,
    suggestedDeposit: String? = nil,
    chainId: UInt64? = Fixture.chainId,
    method: String = "tempo",
    intent: String = "session",
    requestOverride: EncodedJSON? = nil
) throws -> Challenge {
    var details: [String: JSONValue] = [:]
    if let chainId { details["chainId"] = .integer(Int64(chainId)) }
    if let escrow { details["escrowContract"] = .string(escrow) }
    if let suggestedDeposit { details["suggestedDeposit"] = .string(suggestedDeposit) }
    var members: [String: JSONValue] = ["amount": .string(amount)]
    if let recipient { members["recipient"] = .string(recipient) }
    if let currency { members["currency"] = .string(currency) }
    if !details.isEmpty { members["methodDetails"] = .object(details) }
    let request = requestOverride ?? EncodedJSON(json: .object(members))
    return try Challenge(
        id: "session-challenge",
        realm: "https://api.example.com",
        method: MethodName(method),
        intent: IntentName(intent),
        request: request
    )
}

/// The channel id the client should derive for a payee, with the fixed salt and the
/// wallet as both payer and authorized signer.
private func expectedChannelID(payeeHex: String, wallet: EthereumAddress) throws -> Data {
    let payee = try #require(EthereumAddress(hex: payeeHex))
    let token = try #require(EthereumAddress(hex: Fixture.tokenHex))
    let escrow = try #require(EthereumAddress(hex: Fixture.escrowHex))
    let parameters = try #require(Channel.Parameters(
        payer: wallet, payee: payee, token: token, salt: Fixture.salt,
        authorizedSigner: wallet, escrowContract: escrow, chainId: Fixture.chainId
    ))
    return Channel.id(parameters)
}

/// Whether the payload's voucher (channelId + cumulativeAmount + signature) recovers to
/// `wallet` against the fixture escrow and chain.
private func voucherVerifies(
    _ payload: [String: JSONValue],
    wallet: EthereumAddress
) throws -> Bool {
    let channelHex = try #require(payload["channelId"]?.stringValue)
    let channelID = try #require(Data(hexPrefixed: channelHex))
    let cumulative = try #require(payload["cumulativeAmount"]?.stringValue)
    let signatureHex = try #require(payload["signature"]?.stringValue)
    let signature = try #require(Data(hexPrefixed: signatureHex))
    let escrow = try #require(EthereumAddress(hex: Fixture.escrowHex))
    let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: cumulative))
    return voucher.verify(
        escrowContract: escrow, chainId: Fixture.chainId, signature: signature,
        expectedSigner: wallet
    )
}

private extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
