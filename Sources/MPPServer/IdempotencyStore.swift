import Foundation
import HTTPTypes

/// A response captured for idempotent replay: the status, headers, and body of a settled request.
public struct IdempotentResponse: Sendable {
    /// The HTTP response (status and headers) to replay for a settled idempotent request.
    public let response: HTTPResponse
    /// The response body to replay.
    public let body: Data

    /// Creates a captured response for idempotent replay.
    public init(response: HTTPResponse, body: Data) {
        self.response = response
        self.body = body
    }
}

/// What ``IdempotencyStore/begin(_:)`` reports for an `Idempotency-Key`.
public enum IdempotencyOutcome: Sendable {
    /// The key already settled: replay this recorded response and do no payment work.
    case replay(IdempotentResponse)
    /// Another request currently holds the key (in flight); the transport answers `409 Conflict`.
    case inProgress
    /// First to claim the key: process the request, then ``IdempotencyStore/complete(_:response:)``
    /// if it settled, or ``IdempotencyStore/release(_:)`` if it did not.
    case proceed
}

/// Records the response of a settled paid request, keyed on its `Idempotency-Key`, so a client that
/// retries after a lost response (`draft-httpauth-payment-00` §11.4) gets the original result
/// without re-charging on a now-spent challenge.
///
/// Only a SETTLED response (the protected handler ran) is recorded; an unsettled attempt (a `402`,
/// or a transport guard) releases the key so a genuine retry can still pay. A key held by an
/// in-flight request reports ``IdempotencyOutcome/inProgress`` (the transport answers `409`), never
/// processed twice. Like ``ReplayStore``, the claim is atomic.
public protocol IdempotencyStore: Sendable {
    /// Atomically claims `key` for this request, reporting whether to ``IdempotencyOutcome/replay``
    /// a recorded response, that another request is ``IdempotencyOutcome/inProgress``, or to
    /// ``IdempotencyOutcome/proceed``. Claim and lookup are one step so concurrent first-claims of
    /// the same key cannot both proceed.
    func begin(_ key: String) async -> IdempotencyOutcome
    /// Records `response` as the settled result for `key`; a later ``begin(_:)`` replays it.
    func complete(_ key: String, response: IdempotentResponse) async
    /// Releases a `key` claimed by ``begin(_:)`` without recording a response (the request did not
    /// settle), so a later request may claim it and pay. Never erases a recorded response.
    func release(_ key: String) async
}

/// An in-memory ``IdempotencyStore`` backed by an actor (the atomic claim is the actor's
/// serialization). It retains every completed key's response for the process lifetime; a store that
/// bounds memory by expiring keys (SQLite/Redis with a TTL) is a separate implementation, exactly
/// as for ``ReplayStore``.
public actor InMemoryIdempotencyStore: IdempotencyStore {
    private enum State {
        case inProgress
        case completed(IdempotentResponse)
    }

    private var states: [String: State] = [:]

    /// Creates an empty store.
    public init() {}

    public func begin(_ key: String) -> IdempotencyOutcome {
        switch states[key] {
        case let .completed(recorded):
            return .replay(recorded)
        case .inProgress:
            return .inProgress
        case nil:
            states[key] = .inProgress
            return .proceed
        }
    }

    public func complete(_ key: String, response: IdempotentResponse) {
        states[key] = .completed(response)
    }

    public func release(_ key: String) {
        // Only clear an in-progress claim; never erase a recorded response.
        if case .inProgress = states[key] { states[key] = nil }
    }
}
