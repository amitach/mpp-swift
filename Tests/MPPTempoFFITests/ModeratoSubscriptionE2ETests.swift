import Foundation
import MPPCore
import MPPEVM
import MPPTempo
import MPPTempoServer
import Testing
@testable import MPPTempoFFI

// The authoritative on-chain proof of the subscription renewer: against live Moderato, fund a
// payer (root), sign a real TempoKeyAuthorization delegating a fresh access key to
// transferWithMemo, then run TempoSubscriptionRenewer twice -- the provisioning charge (attaches
// the authorization, registers the access key in the keychain, transfers period 0) and a plain
// charge (no authorization, the key is now provisioned) -- and assert the recipient's TIP-20
// balance grows by the per-period amount each time.
//
// Gated behind MPP_MODERATO_E2E=1 (the same gate as the other live tests) AND requires the FFI.
// Self-contained: the faucet funds the payer with native gas + the TIP-20 token. Helpers come from
// ``ModeratoKit``.
private let liveSubscriptionEnabled = ProcessInfo.processInfo.environment["MPP_MODERATO_E2E"] == "1"

@Suite("Moderato subscription renewer e2e")
struct ModeratoSubscriptionE2ETests {
    private let amount: UInt64 = 1000

    @Test(
        "renewer provisions + charges on-chain, then charges again without the authorization",
        .enabled(if: liveSubscriptionEnabled)
    )
    func renewOnChain() async throws {
        let fixture = try await arrange()
        var record = fixture.record

        let before = try await balanceOf(fixture.token, fixture.recipient, rpc: fixture.rpc)

        // Provisioning charge (period 0): attaches the authorization to register the access key.
        let hash0 = try await fixture.renewer.charge(
            record, period: 0, idempotencyReference: "renewal:sub:0"
        )
        let afterProvision = try await balanceOf(fixture.token, fixture.recipient, rpc: fixture.rpc)
        #expect(afterProvision == before + amount)

        // Plain charge (period 1): the key is provisioned, so no authorization is attached.
        record.lastChargedPeriod = 0
        let hash1 = try await fixture.renewer.charge(
            record, period: 1, idempotencyReference: "renewal:sub:1"
        )
        let afterPlain = try await balanceOf(fixture.token, fixture.recipient, rpc: fixture.rpc)
        #expect(afterPlain == afterProvision + amount)
        #expect(hash0 != hash1)
    }

    private struct Fixture {
        let rpc: EVMRPC
        let renewer: TempoSubscriptionRenewer
        let record: SubscriptionRecord
        let token: EthereumAddress
        let recipient: EthereumAddress
    }

    // One linear arrange for the live flow (funds, provisions, signs, assembles).
    // swiftlint:disable function_body_length
    /// Funds a payer, provisions a fresh access key, signs the key authorization, and assembles the
    /// record + renewer (a generous gas limit for the ~4M-gas provisioning; the charge executes as
    /// the payer, so its nonce is the payer's).
    private func arrange() async throws -> Fixture {
        let rpc = try ModeratoKit.makeRPC()
        let token = try #require(EthereumAddress(hex: ModeratoKit.tokenHex))
        let payer = try await ModeratoKit.fundFreshAccount(rpc: rpc)
        let lookupKey = "e2e-subscription"
        let accessKeyPrivateKey = ModeratoKit.randomBytes()
        let accessKeys = InMemoryAccessKeyStore(keyGenerator: { accessKeyPrivateKey })
        let accessKeyAddress = try await accessKeys.provision(forLookupKey: lookupKey)
        let recipient = try #require(EthereumAddress(
            uncompressedPublicKey: Secp256k1Signer(privateKey: ModeratoKit.randomBytes()).publicKey,
        ))
        let periodSeconds: UInt64 = 2_592_000
        let expiry: UInt64 = 1_893_456_000

        let authorization = TempoKeyAuthorization(
            address: accessKeyAddress,
            chainID: ModeratoKit.chainID,
            expiry: expiry,
            limits: [.init(token: token, limit: "1000000", period: periodSeconds)],
            scopes: [
                .init(
                    address: token,
                    selector: SubscriptionRequest.transferWithMemoSelector,
                    recipients: [recipient],
                ),
            ],
        )
        let record = try SubscriptionRecord(
            subscriptionID: "sub",
            lookupKey: lookupKey,
            keyAuthorization: authorization.signedSerialization(with: payer.signer),
            payer: payer.address,
            chainID: ModeratoKit.chainID,
            amount: Amount(String(amount)),
            currency: token,
            recipient: recipient,
            periodSeconds: periodSeconds,
            expiry: expiry,
            billingAnchor: 1_700_000_000,
            lastChargedPeriod: nil,
        )

        let gasPrice = try await rpc.gasPrice()
        let fee = TempoFeeParameters(
            maxFeePerGas: String(gasPrice * 2),
            maxPriorityFeePerGas: "0",
            gasLimit: 6_000_000,
            feeToken: nil,
        )
        // The builder hands the nonce provider the payer (root) account the charge executes for.
        let builder = FFISubscriptionChargeTxBuilder(fee: fee) { account in
            try await rpc.transactionCount(account)
        }
        let renewer = TempoSubscriptionRenewer(
            builder: builder, accessKeys: accessKeys, serverId: "e2e",
        ) { try await rpc.sendRawTransactionSync($0) }

        return Fixture(
            rpc: rpc,
            renewer: renewer,
            record: record,
            token: token,
            recipient: recipient
        )
    }

    // swiftlint:enable function_body_length

    /// TIP-20 `balanceOf(owner)` via `eth_call`; the e2e amounts are small, so the low 8 bytes of
    /// the uint256 result suffice.
    private func balanceOf(
        _ token: EthereumAddress, _ owner: EthereumAddress, rpc: EVMRPC
    ) async throws -> UInt64 {
        let selector = Data([0x70, 0xA0, 0x82, 0x31]) // balanceOf(address)
        let data = selector + Data(repeating: 0, count: 12) + owner.bytes
        let result = try await rpc.call(to: token, data: data)
        return result.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
