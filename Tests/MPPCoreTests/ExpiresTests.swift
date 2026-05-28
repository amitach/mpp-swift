import Foundation
import Testing

@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1 — `expires` is an RFC 3339 date-time.
// Reference comparison:
//   mppx  src/Expires.ts:23   -> assert(...) reads `new Date()` internally
//   mpp-rs src/expires.rs:84  -> compares against `OffsetDateTime::now_utc()`
// Verdict (G3.5): both read the system clock inside the check, which is
// untestable/flaky. We take an explicit `now` instead (anti-flakiness rule #1).
// All time-dependent tests use fixed instants; none read the system clock.
@Suite("Expires")
struct ExpiresTests {
    // Fixed reference instants — deterministic, no system clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z
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
            try Expires("2026-01-01")  // date only, not a date-time
        }
    }

    @Test("isExpired compares against the supplied now, not the system clock")
    func isExpiredUsesSuppliedNow() throws {
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

    @Test("duration helpers offset from the supplied now")
    func durationHelpersOffsetFromNow() {
        #expect(Expires.seconds(30, from: now).date == now.addingTimeInterval(30))
        #expect(Expires.minutes(5, from: now).date == now.addingTimeInterval(300))
        #expect(Expires.hours(2, from: now).date == now.addingTimeInterval(7200))
        #expect(Expires.days(1, from: now).date == now.addingTimeInterval(86_400))
    }

    @Test("encodes transparently and decoding validates")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Expires(Self.utcZ))
        #expect(data == Data("\"\(Self.utcZ)\"".utf8))

        let decoded = try JSONDecoder().decode(Expires.self, from: Data("\"\(Self.utcZ)\"".utf8))
        #expect(decoded.rawValue == Self.utcZ)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Expires.self, from: Data("\"nope\"".utf8))
        }
    }
}
