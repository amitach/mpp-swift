import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// Shared fixtures and helpers for TempoChannelMethodTests (split out so the test file stays
// under the file-length limit). Internal, not private, so the test suite in the sibling file
// can use them; named to avoid clashes with the other MPPTempoTests support.

/// Fixed inputs. The signing key is `0x..01` (the shared proof vector key), so the wallet
/// is `0x7E5F...Bdf`. Addresses have no letters that EIP-55 would re-case, so the literals
/// are also their checksummed form.
enum Fixture {
    static let chainId: UInt64 = 1
    static let key = Data([UInt8](repeating: 0, count: 31) + [1])
    static let escrowHex = "0x000000000000000000000000000000000000eeee"
    static let payeeHex = "0x1111111111111111111111111111111111111111"
    static let payee2Hex = "0x2222222222222222222222222222222222222222"
    static let tokenHex = "0x000000000000000000000000000000000000abcd"
    static let deposit = "1000000"
    static let salt = Data(repeating: 0xAB, count: 32)
    static let txBytes = Data([0x76, 0x01, 0x02, 0x03])
    static let topUpTxBytes = Data([0x76, 0x05, 0x06, 0x07])
}

enum StubError: Error { case boom }

/// A ``TempoTopUpTxBuilder`` that returns canned bytes and records the channel id +
/// additionalDeposit it was handed.
actor StubTopUpTxBuilder: TempoTopUpTxBuilder {
    private let transaction: Data
    private(set) var calls: [(channelID: Data, additionalDeposit: String)] = []

    init(transaction: Data = Fixture.topUpTxBytes) {
        self.transaction = transaction
    }

    func buildTopUpTransaction(
        escrow _: EthereumAddress,
        token _: EthereumAddress,
        channelID: Data,
        additionalDeposit: String,
        chainID _: UInt64
    ) async throws -> Data {
        calls.append((channelID, additionalDeposit))
        return transaction
    }
}

/// A ``TempoOpenTxBuilder`` that returns canned bytes (or fails) and records the
/// parameters it was handed, so a test can assert how many opens ran and with what
/// deposit.
actor StubOpenTxBuilder: TempoOpenTxBuilder {
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
actor SessionRecordingTransport: MPPHTTPTransport {
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

func makeSigner() throws -> Secp256k1Signer {
    try Secp256k1Signer(privateKey: Fixture.key)
}

func makeMethod(
    depositPolicy: @escaping @Sendable (DepositContext) -> String? = { _ in Fixture.deposit },
    approval: TempoApprovalPolicy = .allowAll,
    builder: StubOpenTxBuilder,
    topUpBuilder: (any TempoTopUpTxBuilder)? = nil
) throws -> TempoChannelMethod {
    let method = try TempoChannelMethod(
        signer: makeSigner(),
        openBuilder: builder,
        defaultChainId: Fixture.chainId,
        depositPolicy: depositPolicy,
        approval: approval,
        saltProvider: { Fixture.salt },
        topUpBuilder: topUpBuilder
    )
    return try #require(method)
}

/// A tempo/session challenge whose request carries the charge amount and the
/// `methodDetails` the client resolves the channel from.
func sessionChallenge(
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
    var members: [String: JSONValue] = ["amount": .string(amount)]
    if let recipient { members["recipient"] = .string(recipient) }
    if let currency { members["currency"] = .string(currency) }
    // suggestedDeposit is a top-level request field (sibling of amount), matching the
    // reference session challenge wire, not a methodDetails member.
    if let suggestedDeposit { members["suggestedDeposit"] = .string(suggestedDeposit) }
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
func expectedChannelID(payeeHex: String, wallet: EthereumAddress) throws -> Data {
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
func voucherVerifies(
    _ payload: [String: JSONValue],
    wallet: EthereumAddress
) throws -> Bool {
    let channelHex = try #require(jsonString(payload["channelId"]))
    let channelID = try #require(Data(hexPrefixed: channelHex))
    let cumulative = try #require(jsonString(payload["cumulativeAmount"]))
    let signatureHex = try #require(jsonString(payload["signature"]))
    let signature = try #require(Data(hexPrefixed: signatureHex))
    let escrow = try #require(EthereumAddress(hex: Fixture.escrowHex))
    let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: cumulative))
    return voucher.verify(
        escrowContract: escrow, chainId: Fixture.chainId, signature: signature,
        expectedSigner: wallet
    )
}

/// The string value of a JSON payload entry, or `nil` if absent or not a string.
func jsonString(_ value: JSONValue?) -> String? {
    if case let .string(string) = value { return string }
    return nil
}
