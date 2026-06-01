import Foundation
import MPPCore
import MPPServer
import MPPTempo
import MPPTempoServer

// The live routes link the RPC transport (MPPClient), EVMRPC (MPPEVM), and the FFI charge/close
// builders (MPPTempoFFI), so those imports ride the same gate the routes do.
#if MPP_TEMPO_FFI_ENABLED
    import MPPClient
    import MPPEVM
    import MPPTempoFFI
#endif

// The live (network-settling) reverse-conformance routes, split out of ConformanceServer.swift
// to keep each file focused: these need a real RPC + the FFI charge/close builders, so the whole
// block is FFI-gated. The shared config (chainId, secret, log, the offline recipient) lives in
// ConformanceServer.swift. main() (there) wires
// makeSessionMiddleware/makeSubscriptionLiveMiddleware
// into the router under the same gate.

#if MPP_TEMPO_FFI_ENABLED
    // Reverse session conformance (live on Moderato). The mppx CLIENT opens a channel to
    // our recipient, vouchers, and closes; our SessionMethod relays the open, accepts the
    // vouchers, and settles the close on-chain with the faucet-funded operator key. Gated
    // on the FFI (the close builder) and on CONFORMANCE_OPERATOR_KEY being set.
    private let moderatoRPCURL = "https://rpc.moderato.tempo.xyz"
    private let sessionEscrowHex = "0xe1c4d3dce17bc111181ddf716f75bae49e61a336"
    private let sessionTokenHex = "0x20c0000000000000000000000000000000000000"

    private enum SessionConfigError: Error { case badOperatorKey }

    /// Resolves the on-chain relay/settle provider and the operator (payee) address from the
    /// faucet-funded operator key, or nil if no key is configured (proof-only run).
    private func makeSessionProvider()
        async throws -> (provider: RPCChannelStateProvider, payee: EthereumAddress)? {
        guard let keyHex = ProcessInfo.processInfo.environment["CONFORMANCE_OPERATOR_KEY"],
              let keyData = Data(hexPrefixed: keyHex)
        else { return nil }
        let operatorSigner = try Secp256k1Signer(privateKey: keyData)
        guard let payee = EthereumAddress(uncompressedPublicKey: operatorSigner.publicKey),
              let rpcURL = URL(string: moderatoRPCURL)
        else { throw SessionConfigError.badOperatorKey }
        let rpc = try EVMRPC(transport: URLSessionTransport(), url: rpcURL)
        let gasPrice = try await rpc.gasPrice()
        let builder = FFITempoTxBuilder(
            signingKey: keyData,
            fee: TempoFeeParameters(
                maxFeePerGas: String(gasPrice * 2),
                maxPriorityFeePerGas: "0",
                gasLimit: 2_000_000,
                feeToken: nil
            ),
            nonceProvider: { try await rpc.transactionCount($0) }
        )
        return (RPCChannelStateProvider(rpc: rpc, closeTxBuilder: builder), payee)
    }

    /// Builds the session middleware, or nil if no operator key is configured (proof-only).
    func makeSessionMiddleware() async throws -> MPPServerMiddleware? {
        guard let (provider, payee) = try await makeSessionProvider() else { return nil }
        let sessionMethod = SessionMethod(
            provider: provider, store: InMemoryChannelStore(), defaultChainID: chainId
        )
        let signer = ChallengeSigner(secret: secret)
        let binding = try RouteBinding(
            realm: "127.0.0.1", method: MethodName("tempo"), intent: .session
        )
        // The session 402 the mppx client opens against: amount + payee (our operator) +
        // currency + a top-level suggestedDeposit + methodDetails.{chainId, escrowContract}.
        let request = EncodedJSON(json: .object([
            "amount": .string("1"),
            "recipient": .string(payee.checksummed),
            "currency": .string(sessionTokenHex),
            "suggestedDeposit": .string("1000"),
            "methodDetails": .object([
                "chainId": .integer(Int64(chainId)),
                "escrowContract": .string(sessionEscrowHex),
            ]),
        ]))
        return MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            // A normal one-time replay store is fine: SessionMethod.reusesChallenge tells the
            // verifier not to consume the challenge id (the channel cumulative is the
            // anti-replay), so the same challenge serves open, vouchers, and close.
            verifier: PaymentVerifier(
                signer: signer, replayStore: InMemoryReplayStore(), methods: [sessionMethod]
            ),
            binding: binding,
            request: request
        ) { event in
            switch event {
            case let .challengeIssued(challenge):
                log("[server] issued 402 (session) id=\(challenge.id)")
            case let .paymentVerified(verified):
                log("[server] VERIFIED (session) source=\(verified.credential.source ?? "nil")")
            case let .paymentRejected(rejection):
                log("[server] rejected (session) \(rejection)")
            }
        }
    }

    // Reverse subscription conformance, LIVE: the mppx CLIENT activates a subscription against our
    // server with a faucet-funded payer; our server activates it AND settles period 0 on-chain
    // (charge-on-activate, matching the reference SDK's activate hook). The recurring
    // transferWithMemo
    // is signed by the server-held access key as a keychain signature on behalf of the payer
    // (root),
    // so the payer's TIP-20 funds move to the recipient. Gated on the FFI (the charge builder).

    /// A conformance verifier that activates a subscription AND immediately settles period 0
    /// on-chain
    /// (the activation request is the renewal trigger here, standing in for a production
    /// scheduler).
    private struct ActivateThenChargeVerifier: PaymentMethodServer {
        let activating: ActivatingSubscriptionVerifier
        let engine: SubscriptionEngine
        let resolveIdentity: @Sendable (Credential) async throws -> ActivatingSubscriptionVerifier
            .Identity

        func supports(_ challenge: Challenge) -> Bool {
            activating.supports(challenge)
        }

        var reusesChallenge: Bool {
            activating.reusesChallenge
        }

        func verify(_ credential: Credential, now: Date) async throws -> Receipt {
            let receipt = try await activating.verify(credential, now: now)
            let identity = try await resolveIdentity(credential)
            let outcome = try await engine.renew(
                subscriptionID: identity.subscriptionID, now: UInt64(now.timeIntervalSince1970)
            )
            log("[server] CHARGED (subscription-live) \(outcome)")
            return receipt
        }
    }

    func makeSubscriptionLiveMiddleware() async throws -> MPPServerMiddleware? {
        guard let rpcURL = URL(string: moderatoRPCURL) else { return nil }
        let rpc = try EVMRPC(transport: URLSessionTransport(), url: rpcURL)
        let lookupKey = "conformance-subscription-live"
        let accessKeys = InMemoryAccessKeyStore()
        let accessKeyAddress = try await accessKeys.provision(forLookupKey: lookupKey)
        let renewer = try await makeLiveRenewer(rpc: rpc, accessKeys: accessKeys)
        let engine = SubscriptionEngine(store: InMemorySubscriptionStore(), renewer: renewer)
        let identity: @Sendable (Credential) -> ActivatingSubscriptionVerifier
            .Identity = { credential in
                .init(subscriptionID: credential.challenge.id, lookupKey: lookupKey)
            }
        let method = ActivateThenChargeVerifier(
            activating: ActivatingSubscriptionVerifier(
                verifier: TempoSubscriptionVerifier(defaultChainID: chainId), engine: engine
            ) { identity($0) },
            engine: engine
        ) { identity($0) }
        let signer = ChallengeSigner(secret: secret)
        let binding = try RouteBinding(
            realm: "127.0.0.1", method: MethodName("tempo"), intent: .subscription
        )
        return MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            verifier: PaymentVerifier(
                signer: signer, replayStore: InMemoryReplayStore(), methods: [method]
            ),
            binding: binding,
            request: subscriptionLiveRequest(accessKeyAddress: accessKeyAddress)
        ) { event in
            switch event {
            case let .challengeIssued(challenge):
                log("[server] issued 402 (subscription-live) id=\(challenge.id)")
            case let .paymentVerified(verified):
                let source = verified.credential.source ?? "nil"
                log("[server] ACTIVATED (subscription-live) source=\(source)")
            case let .paymentRejected(rejection):
                log("[server] rejected (subscription-live) \(rejection)")
            }
        }
    }

    /// Builds the on-chain renewer for the live route. A faucet-funded gas sponsor (fee payer)
    /// pays gas so the access key's per-period spending limit (== the charge amount) only has to
    /// cover the transfer: the chain meters gas in the fee token and would otherwise draw it from
    /// that same limit, reverting with SpendingLimitExceeded. The shell harness funds
    /// CONFORMANCE_FEE_PAYER_KEY's address before boot; absent the env var, the payer pays its own
    /// gas (and the live charge would need limit > amount).
    private func makeLiveRenewer(
        rpc: EVMRPC, accessKeys: InMemoryAccessKeyStore
    ) async throws -> TempoSubscriptionRenewer {
        let gasPrice = try await rpc.gasPrice()
        let fee = TempoFeeParameters(
            maxFeePerGas: String(gasPrice * 2),
            maxPriorityFeePerGas: "0",
            gasLimit: 6_000_000, // provisioning is ~4M gas
            feeToken: nil
        )
        let feePayerKey = ProcessInfo.processInfo.environment["CONFORMANCE_FEE_PAYER_KEY"]
            .flatMap { Data(hexPrefixed: $0) }
        let feePayer: (@Sendable () async -> Data?)? = feePayerKey
            .map { key in { @Sendable in key } }
        return TempoSubscriptionRenewer(
            builder: FFISubscriptionChargeTxBuilder(fee: fee) { try await rpc.transactionCount($0)
            },
            accessKeys: accessKeys,
            serverId: "conformance",
            feePayer: feePayer
        ) { try await rpc.sendRawTransactionSync($0) }
    }

    /// The subscription-live 402 request: the faucet token (so the funded payer has balance) plus a
    /// small per-period amount and the provisioned access key the mppx client signs for.
    private func subscriptionLiveRequest(accessKeyAddress: EthereumAddress) -> EncodedJSON {
        EncodedJSON(json: .object([
            "amount": .string("1000"),
            "currency": .string(sessionTokenHex),
            "recipient": .string(subscriptionRecipientHex),
            "periodCount": .string("30"),
            "periodUnit": .string("day"),
            "subscriptionExpires": .string("2030-01-01T00:00:00.000Z"),
            "methodDetails": .object([
                "accessKey": .object([
                    "accessKeyAddress": .string(accessKeyAddress.checksummed),
                    "keyType": .string("secp256k1"),
                ]),
                "chainId": .integer(Int64(chainId)),
            ]),
        ]))
    }
#endif
