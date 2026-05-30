import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo
@testable import MPPTempoFFI

// Forward cross-SDK CHANNEL conformance: our Swift client (`PaymentClient` +
// `TempoChannelMethod` + the FFI open-tx builder) opens a payment channel against the
// reference mppx SESSION server, accumulates an off-chain voucher, and settles it, all
// live on the Moderato testnet. A PASS means the reference server relayed OUR signed open
// on-chain, accepted OUR voucher, and settled OUR voucher (escrow.close) with its operator.
//
// Live + funded: gated on MPP_CONFORMANCE_SESSION_URL (set by run-session.sh, which boots
// the mppx session server) AND on MPP_TEMPO_FFI (this target only exists when the FFI is
// built, since the open tx needs it). Funding is self-contained via the Moderato faucet.
// Skipped by the default `swift test`, so hermetic CI is unaffected.
private let sessionURL = ProcessInfo.processInfo.environment["MPP_CONFORMANCE_SESSION_URL"]

@Suite(.enabled(if: sessionURL != nil))
struct ConformanceSessionTests {
    @Test("open -> voucher -> close against the mppx session server, settled on-chain")
    func channelLifecycleAgainstMppx() async throws {
        let raw = try #require(sessionURL)
        let url = try #require(URL(string: raw))
        let scheme = try #require(url.scheme)
        let host = try #require(url.host(percentEncoded: false))
        let authority = url.port.map { "\(host):\($0)" } ?? host
        let path = url.path.isEmpty ? "/" : url.path

        let rpc = try ModeratoKit.makeRPC()
        let escrow = try #require(EthereumAddress(hex: ModeratoKit.escrowHex))

        // Fund a fresh payer (gas + the TIP-20 it deposits) and build the client method
        // over the live chain. The deposit comes from the server's suggestedDeposit.
        let payer = try await ModeratoKit.fundFreshAccount(rpc: rpc)
        let builder = try await ModeratoKit.makeBuilder(signingKey: payer.privateKey, rpc: rpc)
        let recorder = CredentialRecorder()
        let maybeMethod = TempoChannelMethod(
            signer: payer.signer,
            openBuilder: builder,
            defaultChainId: ModeratoKit.chainID,
            depositPolicy: { $0.suggestedDeposit }
        )
        let method = try #require(maybeMethod)
        let transport = URLSessionTransport()
        let client = PaymentClient(
            transport: transport,
            methods: [method],
            allowInsecureLocal: true,
            onEvent: { event in
                if case let .credentialCreated(credential) = event { recorder.add(credential) }
            }
        )
        let request = HTTPRequest(method: .get, scheme: scheme, authority: authority, path: path)

        // Charge 1 opens the channel (mppx relays our signed open on-chain); charge 2
        // vouchers against it. The session server gates non-content requests as 204.
        let (openResponse, _) = try await client.send(request)
        #expect(openResponse.status.code < 300)
        let (voucherResponse, _) = try await client.send(request)
        #expect(voucherResponse.status.code < 300)

        // The latest credential is the voucher: it carries the channel id and the cumulative
        // the client signed for. Confirm the channel is open on-chain (mppx relayed it).
        let latest = try #require(recorder.last)
        let channelID = try #require(hex(latest.payload["channelId"]))
        let cumulative = try #require(string(latest.payload["cumulativeAmount"]))
        #expect(latest.payload["action"] == .string("voucher"))
        let onChain = try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
        #expect(onChain.deposit > .zero)

        // Close: our client has no close action yet (a deferred follow-up), so build the
        // close credential directly from the latest voucher and let the mppx server settle
        // it on-chain with its operator. Reuses Voucher.sign + Credential.
        try await close(
            latest: latest,
            escrow: escrow,
            payer: payer,
            transport: transport,
            request: request
        )

        // The reference server settled OUR voucher: the channel is finalized on-chain.
        let settled = try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
        #expect(settled.finalized)
    }

    /// Sends a `close` session credential (signed over the latest voucher) so the mppx
    /// server settles it on-chain. Drives the 402 by hand (the close is client-initiated,
    /// not a charge the method handles): GET the endpoint, take the session challenge,
    /// attach the close credential, expect acceptance.
    private func close(
        latest: Credential,
        escrow: EthereumAddress,
        payer: ModeratoKit.Account,
        transport: URLSessionTransport,
        request: HTTPRequest
    ) async throws {
        let channelID = try #require(hex(latest.payload["channelId"]))
        let cumulative = try #require(string(latest.payload["cumulativeAmount"]))
        let (challengeResponse, _) = try await transport.send(request, body: Data())
        #expect(challengeResponse.status.code == 402)
        let header = try #require(challengeResponse.headerFields[values: .wwwAuthenticate].first)
        let challenge = try #require(Challenge.challenges(inHeaderValue: header).first)
        let chainID = (try? TempoChargeRequest(challenge: challenge))?.chainId ?? ModeratoKit
            .chainID

        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: cumulative))
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: chainID,
            with: payer.signer
        )
        let payload: [String: JSONValue] = [
            "action": .string("close"),
            "channelId": .string(channelID.hexPrefixed),
            "cumulativeAmount": .string(cumulative),
            "signature": .string(signature.hexPrefixed),
        ]
        let credential = Credential(
            challenge: challenge,
            source: ProofSource.did(address: payer.address, chainId: chainID),
            payload: payload
        )
        var retry = request
        retry.headerFields[.authorization] = try credential.headerValue
        let (closeResponse, _) = try await transport.send(retry, body: Data())
        #expect(closeResponse.status.code < 300)
    }

    private func hex(_ value: JSONValue?) -> Data? {
        string(value).flatMap(Data.init(hexPrefixed:))
    }

    private func string(_ value: JSONValue?) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }
}

/// A lock-guarded recorder for the synchronous `onEvent` sink (the sends are sequential, but
/// the closure is `@Sendable`, so guard the array). Captures the credentials the client emits.
private final class CredentialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [Credential] = []

    func add(_ credential: Credential) {
        lock.lock()
        defer { lock.unlock() }
        credentials.append(credential)
    }

    var last: Credential? {
        lock.lock()
        defer { lock.unlock() }
        return credentials.last
    }
}
