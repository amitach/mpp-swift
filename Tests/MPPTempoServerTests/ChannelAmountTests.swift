import Testing
@testable import MPPTempoServer

// A uint128 amount type: exact add / subtract / compare across the 64-bit boundary,
// since channel amounts (token deposits, cumulative vouchers) routinely exceed
// UInt64 and the package targets below the stdlib UInt128.
@Suite("ChannelAmount")
struct ChannelAmountTests {
    @Test("parses decimal values, including beyond UInt64 up to 2^128 - 1")
    func parsesDecimal() {
        #expect(ChannelAmount(decimal: "0") == .zero)
        #expect(ChannelAmount(decimal: "42") == ChannelAmount(42))
        // 2^64 carries into the high word.
        #expect(ChannelAmount(decimal: "18446744073709551616") == ChannelAmount(high: 1, low: 0))
        // 2^128 - 1 is the maximum.
        #expect(ChannelAmount(decimal: "340282366920938463463374607431768211455")
            == ChannelAmount(high: .max, low: .max))
    }

    @Test("rejects empty, non-ASCII-digit, leading-zero, and values >= 2^128")
    func rejectsInvalid() {
        #expect(ChannelAmount(decimal: "") == nil)
        #expect(ChannelAmount(decimal: "12a") == nil)
        #expect(ChannelAmount(decimal: "-1") == nil)
        // Non-ASCII numerals (Arabic-Indic "12") a reference SDK would reject.
        #expect(ChannelAmount(decimal: "\u{0661}\u{0662}") == nil)
        // No leading zeros (canonical grammar 0 / [1-9][0-9]*); bare "0" is fine.
        #expect(ChannelAmount(decimal: "007") == nil)
        #expect(ChannelAmount(decimal: "0") == .zero)
        // 2^128 overflows.
        #expect(ChannelAmount(decimal: "340282366920938463463374607431768211456") == nil)
    }

    @Test("compares across the 64-bit boundary")
    func compares() {
        #expect(ChannelAmount(high: 1, low: 0) > ChannelAmount(.max))
        #expect(ChannelAmount(5) < ChannelAmount(6))
        #expect(ChannelAmount(high: 1, low: 0) == ChannelAmount(decimal: "18446744073709551616"))
    }

    @Test("adds with carry and reports overflow")
    func adds() {
        #expect(ChannelAmount(.max).adding(ChannelAmount(1)) == ChannelAmount(high: 1, low: 0))
        #expect(ChannelAmount(high: .max, low: .max).adding(ChannelAmount(1)) == nil)
    }

    @Test("subtracts with borrow and reports underflow")
    func subtracts() {
        #expect(ChannelAmount(high: 1, low: 0).subtracting(ChannelAmount(1)) == ChannelAmount(.max))
        #expect(ChannelAmount(5).subtracting(ChannelAmount(10)) == nil)
        let max = ChannelAmount(high: .max, low: .max)
        #expect(max.subtracting(max) == .zero)
    }
}
