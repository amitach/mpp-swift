import Foundation
import MPPEVM

/// The read side of the Tempo stream-channel escrow: encode the `getChannel` view
/// call and decode its return into an ``OnChainChannel``. Blob-free (plain ABI over
/// ``EVMRPC``), so a client/wallet and the server both read channel state without
/// the transaction-builder FFI.
///
/// The write side (open / topUp / close transactions) is the `0x76` transaction
/// layer (FFI), not here. The view ABI, per the escrow contract:
///
/// ```solidity
/// function getChannel(bytes32 channelId) external view returns (
///     bool finalized, uint64 closeRequestedAt,
///     address payer, address payee, address token, address authorizedSigner,
///     uint128 deposit, uint128 settled
/// );
/// ```
public enum TempoEscrow {
    /// The 4-byte selector for `getChannel(bytes32)` (first 4 bytes of its Keccak-256
    /// hash), computed once rather than hardcoded so it cannot drift from the name.
    public static let getChannelSelector = Data(
        Keccak256.hash(Data("getChannel(bytes32)".utf8)).prefix(4)
    )

    /// The call data for `getChannel(channelID)`: the selector followed by the
    /// 32-byte channel id. `nil` if `channelID` is not exactly 32 bytes.
    public static func getChannelCallData(channelID: Data) -> Data? {
        guard channelID.count == 32 else { return nil }
        return getChannelSelector + channelID
    }

    /// Decodes a `getChannel` return (eight 32-byte ABI words, all static) into an
    /// ``OnChainChannel``, or `nil` if it is shorter than eight words or an address
    /// word is malformed.
    public static func decodeChannel(_ data: Data) -> OnChainChannel? {
        guard data.count >= 32 * 8 else { return nil }
        let base = data.startIndex
        func word(_ index: Int) -> Data {
            let start = base + index * 32
            return Data(data[start ..< start + 32])
        }
        // ABI statics are right-aligned in their 32-byte word: an address is the low
        // 20 bytes, a uint128 the low 16, a uint64 the low 8, a bool the low byte.
        func address(_ index: Int) -> EthereumAddress? {
            EthereumAddress(bytes: Data(word(index).suffix(20)))
        }
        func uint64(_ index: Int) -> UInt64 {
            word(index).suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func uint128(_ index: Int) -> ChannelAmount {
            let low16 = Data(word(index).suffix(16))
            let high = low16.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let low = low16.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return ChannelAmount(high: high, low: low)
        }
        guard let payer = address(2), let payee = address(3),
              let token = address(4), let authorizedSigner = address(5)
        else { return nil }
        return OnChainChannel(
            payer: payer,
            payee: payee,
            token: token,
            authorizedSigner: authorizedSigner,
            deposit: uint128(6),
            settled: uint128(7),
            finalized: word(0).last != 0,
            closeRequestedAt: uint64(1)
        )
    }

    /// Reads `channelID`'s on-chain state from `escrow` via `rpc` (an `eth_call`).
    public static func readChannel(
        _ channelID: Data, escrow: EthereumAddress, via rpc: EVMRPC
    ) async throws(EVMRPCError) -> OnChainChannel {
        guard let callData = getChannelCallData(channelID: channelID) else {
            throw .malformedResponse("channelId must be 32 bytes")
        }
        let returned = try await rpc.call(to: escrow, data: callData)
        guard let channel = decodeChannel(returned) else {
            throw .malformedResponse("getChannel return is not eight ABI words")
        }
        return channel
    }
}
