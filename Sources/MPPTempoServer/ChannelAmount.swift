import Foundation

/// A 128-bit unsigned integer for payment-channel amounts (a `uint128` on the
/// wire and on-chain: deposits, cumulative voucher amounts, spend counters).
///
/// Channel accounting needs exact `uint128` add / subtract / compare, but the
/// package targets below macOS 15 / iOS 18, where the standard-library `UInt128`
/// is unavailable, and (per `EIP712`'s amount encoder) a big-integer dependency is
/// unwarranted. So this is a minimal in-house `uint128` as a high/low `UInt64`
/// pair, with checked arithmetic (overflow and underflow surface as `nil` rather
/// than trapping or wrapping, since an amount that does not fit or would go
/// negative is a verification failure, not a crash).
public struct ChannelAmount: Sendable, Hashable, Comparable {
    /// The high 64 bits.
    public let high: UInt64
    /// The low 64 bits.
    public let low: UInt64

    /// Zero.
    public static let zero = ChannelAmount(high: 0, low: 0)

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// A value that fits in 64 bits.
    public init(_ value: UInt64) {
        high = 0
        low = value
    }

    /// Parses a canonical base-10 unsigned integer string, or `nil` if it is
    /// empty, holds a non-ASCII-digit, has a leading zero, or exceeds `2^128 - 1`.
    ///
    /// Canonical means the grammar `0 / [1-9][0-9]*` (matching `Amount`): only
    /// ASCII `0`...`9` (never a Unicode numeral like `١`, which a reference SDK
    /// would reject), and no leading zeros, so a value has one wire spelling.
    public init?(decimal text: String) {
        guard !text.isEmpty else { return nil }
        if text.count > 1, text.first == "0" { return nil } // no leading zeros
        var result = ChannelAmount.zero
        for character in text {
            guard ("0" ... "9").contains(character), let digit = character.wholeNumberValue else {
                return nil
            }
            guard
                let times10 = result.multipliedByTen(),
                let next = times10.adding(ChannelAmount(UInt64(digit)))
            else { return nil }
            result = next
        }
        self = result
    }

    public static func < (lhs: ChannelAmount, rhs: ChannelAmount) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }

    /// `self + other`, or `nil` on overflow past `2^128 - 1`.
    public func adding(_ other: ChannelAmount) -> ChannelAmount? {
        let (low, lowCarry) = low.addingReportingOverflow(other.low)
        let (highPartial, highOverflow1) = high.addingReportingOverflow(other.high)
        guard !highOverflow1 else { return nil }
        let (high, highOverflow2) = highPartial.addingReportingOverflow(lowCarry ? 1 : 0)
        guard !highOverflow2 else { return nil }
        return ChannelAmount(high: high, low: low)
    }

    /// `self - other`, or `nil` if `other > self` (would underflow).
    public func subtracting(_ other: ChannelAmount) -> ChannelAmount? {
        guard self >= other else { return nil }
        let (low, borrow) = low.subtractingReportingOverflow(other.low)
        // self >= other guarantees the high subtraction does not underflow.
        let high = high - other.high - (borrow ? 1 : 0)
        return ChannelAmount(high: high, low: low)
    }

    /// `self * 10`, or `nil` on overflow (used by decimal parsing).
    private func multipliedByTen() -> ChannelAmount? {
        // 10x = 8x + 2x = (self << 3) + (self << 1).
        guard let eight = shiftedLeft(by: 3), let two = shiftedLeft(by: 1) else { return nil }
        return eight.adding(two)
    }

    /// `self << count` for a small `count`, or `nil` if any set bit is shifted out.
    private func shiftedLeft(by count: UInt64) -> ChannelAmount? {
        guard count > 0 else { return self }
        guard count < 64 else { return nil } // only small shifts are needed
        guard high >> (64 - count) == 0 else { return nil } // high bits would be lost
        let newHigh = (high << count) | (low >> (64 - count))
        let newLow = low << count
        return ChannelAmount(high: newHigh, low: newLow)
    }
}
