import Foundation
import MPPBodyDigest
import MPPCore

/// Verifies an `Authorization: Payment` credential against this server's secret:
/// the protocol-level gate that turns an untrusted request into an ``MPPVerified``
/// token, or a typed rejection.
///
/// The pipeline runs in order: parse the credential; confirm its echoed challenge
/// is one this server signed (HMAC, via ``ChallengeSigner``); confirm the
/// challenge's realm/method/intent match the route's ``RouteBinding``; confirm
/// it has not expired; confirm the request body matches the challenge digest
/// (when the challenge carries one); consume the single-use challenge id
/// (``ReplayStore``); then run the method-specific settlement (when
/// ``PaymentMethodServer`` verifiers are registered).
///
/// Consume runs BEFORE method settlement on purpose: a method's settlement may
/// perform side effects (a session broadcasts a transaction and charges), so a
/// replayed credential must be rejected at the single-use consume before any side
/// effect can run, not after. Consume fails closed (if first use cannot be
/// confirmed, reject), so a rejected one-shot credential burns its challenge id and
/// the client retries on a fresh `402`. A method that reuses its challenge (a
/// session) skips the one-time consume and enforces its own atomic anti-replay (the
/// monotonic channel cumulative). With verifiers registered, a challenge no verifier
/// supports is rejected (fail closed).
public struct PaymentVerifier: Sendable {
    private let signer: ChallengeSigner
    private let replayStore: any ReplayStore
    private let methods: [any PaymentMethodServer]

    /// Creates a verifier over the server's challenge signer and replay store, and
    /// an optional set of ``PaymentMethodServer`` settlement verifiers.
    ///
    /// With no `methods` (the default), verification is protocol-only, exactly as
    /// before: the ``MPPVerified`` token attests the protocol checks and the caller
    /// is responsible for any settlement check. With `methods` registered, the one
    /// that ``PaymentMethodServer/supports(_:)`` the challenge must also verify the
    /// settlement before the credential is accepted, and a challenge that no
    /// registered method supports is rejected (fail closed) rather than granted on
    /// the protocol checks alone.
    public init(
        signer: ChallengeSigner,
        replayStore: any ReplayStore,
        methods: [any PaymentMethodServer] = []
    ) {
        self.signer = signer
        self.replayStore = replayStore
        self.methods = methods
    }

    /// Verifies the `Authorization: Payment` header value against `body` as of
    /// `now`, for a route that requires `expecting`.
    ///
    /// `expecting` is required, not optional: the HMAC proves only that this
    /// server issued *a* challenge with the credential's realm/method/intent, not
    /// that they match the resource being accessed. Pinning them here prevents a
    /// confused-deputy / cross-route replay (a credential minted for a cheap
    /// route presented to an expensive one under a shared secret). A nil-able
    /// default would let a caller silently skip the pin, so the parameter is
    /// mandatory.
    public func verify(
        authorization: String,
        body: Data,
        now: Date,
        expecting: RouteBinding
    ) async -> Outcome {
        let credential: Credential
        switch protocolCheck(
            authorization: authorization,
            body: body,
            now: now,
            expecting: expecting
        ) {
        case let .rejected(rejection): return .rejected(rejection)
        case let .valid(checked): credential = checked
        }
        let challenge = credential.challenge

        // Resolve the settling method: with verifiers registered, the matching one must accept;
        // none supporting a route-bound challenge is fail-closed.
        let method = methods.first { $0.supports(challenge) }
        if method == nil, !methods.isEmpty { return .rejected(.noSupportingMethod) }

        // Consume the single-use challenge BEFORE running the method, so a replayed credential is
        // rejected before any method side effect (a method's `verify` may broadcast or charge: the
        // consume must gate the side effect, not follow it). A method that reuses its challenge (a
        // session) skips this and enforces its own atomic anti-replay (the monotonic cumulative);
        // one-time consumption would otherwise reject every voucher after the open.
        if !(method?.reusesChallenge ?? false) {
            guard await replayStore.consume(challenge.id) else { return .rejected(.replayed) }
        }

        // The method mints its own receipt (base fields plus any method extras), stamped with the
        // injected `now`. The verifier only carries it.
        guard let method else {
            return .verified(MPPVerified(credential: credential, receipt: nil))
        }
        do {
            let receipt = try await method.verify(credential, now: now)
            return .verified(MPPVerified(credential: credential, receipt: receipt))
        } catch {
            return .rejected(.settlementUnverified(reason: String(describing: error)))
        }
    }

    /// The outcome of the protocol-level checks: the parsed credential, or the rejection. A private
    /// result type (`Result`'s `Failure` must be `Error`, which `Rejection` is deliberately not).
    private enum ProtocolCheck {
        case valid(Credential)
        case rejected(Rejection)
    }

    /// The protocol-level checks (parse, HMAC challenge binding, route pin, expiry, body digest)
    /// that gate every credential before settlement; returns the parsed credential or a rejection.
    private func protocolCheck(
        authorization: String, body: Data, now: Date, expecting: RouteBinding
    ) -> ProtocolCheck {
        guard let credential = try? Credential(headerValue: authorization) else {
            return .rejected(.malformedCredential)
        }
        let challenge = credential.challenge
        // The id is an HMAC over the challenge's binding input; this proves the server issued
        // exactly these (unmodified) challenge parameters.
        guard signer.verify(challenge) else { return .rejected(.invalidChallenge) }
        // ...but not that they are this route's parameters: pin them.
        guard expecting.matches(challenge) else { return .rejected(.bindingMismatch) }
        if let expires = challenge.expires, expires.isExpired(at: now) {
            return .rejected(.expired)
        }
        // A malformed digest in our own signed challenge, or a body mismatch, both reject (fail
        // closed); no digest is a pass.
        guard digestMatches(challenge, body: body) else { return .rejected(.digestMismatch) }
        return .valid(credential)
    }

    /// Whether `body` satisfies the challenge's Content-Digest: `true` when the challenge
    /// carries no digest, otherwise the body must match (a malformed digest fails closed).
    private func digestMatches(_ challenge: Challenge, body: Data) -> Bool {
        guard let digest = challenge.digest else { return true }
        return (try? ContentDigest.verify(body, matches: digest)) == true
    }

    /// The result of verifying a credential.
    public enum Outcome: Sendable {
        /// The credential is protocol-valid; the request may be served.
        case verified(MPPVerified)
        /// The credential was rejected; the server answers `402` with the
        /// corresponding problem.
        case rejected(Rejection)
    }

    /// Why a credential was rejected.
    public enum Rejection: Sendable, Hashable {
        /// The Authorization value was not a parseable `Payment` credential.
        case malformedCredential
        /// The echoed challenge was not signed by this server (bad id binding).
        case invalidChallenge
        /// The challenge's realm/method/intent did not match the route's
        /// (a credential minted for a different resource).
        case bindingMismatch
        /// The challenge had expired as of `now`.
        case expired
        /// The request body did not match the challenge's content digest.
        case digestMismatch
        /// The challenge id had already been consumed (replay).
        case replayed
        /// A settlement verifier is registered but none supports this challenge
        /// (fail closed: the resource is not granted on the protocol checks alone).
        case noSupportingMethod
        /// The method-specific settlement check rejected the credential (for a
        /// proof, the signature did not recover to the `source` wallet). `reason`
        /// carries the method error's description for diagnostics.
        case settlementUnverified(reason: String)
    }
}
