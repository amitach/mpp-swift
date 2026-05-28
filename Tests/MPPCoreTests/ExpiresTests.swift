import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1: `expires` is an RFC 3339 date-time.
// Expiry checks take an explicit `now` rather than reading the system clock,
// so the check is deterministic (anti-flakiness rule #1).
// All time-dependent tests use fixed instants; none read the system clock.
@Suite("Expires")
struct ExpiresTests {
    // Fixed reference instants: deterministic, no system clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
    private static let utcZ = "2026-01-01T00:00:00Z"

    @Test("parses RFC 3339 with Z and preserves the original string verbatim")
    func parsesAndPreservesRawValue() throws {
        let expires = try Expires(Self.utcZ)
        #expect(expires.rawValue == Self.utcZ)
    }

    @Test("parses RFC 3339 with fractional seconds and with a numeric offset")
    func parsesFractionalAndOffset() throws {
        #expect(throws: Never.self) { try Expires("2026-01-01T00:00:00.123Z") }
        #expect(throws: Never.self) { try Expires("2026-01-01T05:30:00+05:30") }
    }

    @Test("rejects a malformed timestamp")
    func rejectsMalformed() {
        #expect(throws: Expires.ParsingError.malformed) {
            try Expires("not-a-date")
        }
        #expect(throws: Expires.ParsingError.malformed) {
            try Expires("2026-01-01") // date only, not a date-time
        }
    }

    @Test("isExpired compares against the supplied now, not the system clock")
    func isExpiredUsesSuppliedNow() {
        let past = Expires(date: now.addingTimeInterval(-1))
        let future = Expires(date: now.addingTimeInterval(1))
        #expect(past.isExpired(at: now))
        #expect(!future.isExpired(at: now))
    }

    @Test("validate throws for an expired challenge and carries the expiry")
    func validateThrowsWhenExpired() throws {
        let past = Expires(date: now.addingTimeInterval(-60))
        #expect(throws: Expires.ExpiredError(expires: past.rawValue)) {
            try past.validate(at: now)
        }
        #expect(throws: Never.self) {
            try Expires(date: now.addingTimeInterval(60)).validate(at: now)
        }
    }

    // Boundary at the exact expiry instant. The validity window is `now <=
    // expires`: a challenge is valid AT its expiry instant and expired only once
    // `now` is strictly past it. The draft is silent on the instant; this pins
    // the interop-verified behaviour (both reference SDKs compare with strict
    // `<`). `now` is a whole second, so `Expires(date:)` round-trips it exactly
    // and the comparison lands on the boundary, not a sub-second rounding artefact.
    @Test("isExpired: valid at the exact expiry instant, expired one second after")
    func isExpiredAtExactBoundary() {
        let expires = Expires(date: now)
        // now == expires -> valid (boundary is inclusive)
        #expect(!expires.isExpired(at: now))
        // now == expires - 1s -> valid
        #expect(!expires.isExpired(at: now.addingTimeInterval(-1)))
        // now == expires + 1s -> expired
        #expect(expires.isExpired(at: now.addingTimeInterval(1)))
    }

    @Test("validate succeeds at the exact expiry instant, throws one second after")
    func validateAtExactBoundary() throws {
        let expires = Expires(date: now)
        #expect(throws: Never.self) {
            try expires.validate(at: now)
        }
        #expect(throws: Expires.ExpiredError(expires: expires.rawValue)) {
            try expires.validate(at: now.addingTimeInterval(1))
        }
    }
}
