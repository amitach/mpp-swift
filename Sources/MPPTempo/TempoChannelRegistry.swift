import Foundation
import MPPEVM

/// The registry key for a payment channel: the `(payee, token, escrow, chainId)` a channel
/// is reused for. Every charge to the same key vouchers against one open channel; only the
/// first charge opens it. `chainId` is included (the reference client keys only by the
/// triple) because it binds the voucher's EIP-712 domain and the on-chain channel id: the
/// same `(payee, token, escrow)` on two chains is two distinct channels, and the key is
/// internal client state (never on the wire), so adding it is a correctness fix with no
/// protocol impact.
struct ChannelKey: Hashable {
    let payee: EthereumAddress
    let token: EthereumAddress
    let escrow: EthereumAddress
    let chainId: UInt64
}

/// A freshly opened channel: the deterministic 32-byte channel id and the signed
/// `0x76` open transaction the server relays. The salt is not carried because nothing
/// downstream needs it (the channel id already commits to it, and the server reads the
/// on-chain channel).
struct OpenedChannel {
    let channelID: Data
    let transaction: Data
}

/// What a charge resolved to: a fresh `open` (the first charge to a key) or a `voucher`
/// against an already-open channel (every subsequent charge). Both carry the cumulative
/// amount the voucher must be signed for.
enum ChannelOutcome {
    case open(channelID: Data, cumulative: ChannelAmount, transaction: Data)
    case voucher(channelID: Data, cumulative: ChannelAmount)
}

/// The per-client store of open channels, keyed by ``ChannelKey``. It tracks the
/// monotonic cumulative amount per channel (mirroring mppx, which increments the
/// cumulative locally per charge rather than reading it back), and serializes the
/// first-charge open per key so concurrent charges to a new recipient open exactly one
/// channel.
///
/// It is an `actor`, so the cumulative increment is atomic. But actor reentrancy means a
/// method yields at an `await`, so the open is gated with a stored in-flight `Task`: the
/// check-then-register of that task is synchronous (no `await` between), so two charges
/// to the same new key cannot both start an open; the second awaits the first's task,
/// then loops and vouchers against the now-open entry. (PR-G lesson: an actor does not
/// serialize across an `await`, so the synchronous gate is what makes this safe.)
actor TempoChannelRegistry {
    /// The tracked state of one open channel.
    private struct Entry {
        let channelID: Data
        var cumulative: ChannelAmount
    }

    private var entries: [ChannelKey: Entry] = [:]
    private var opens: [ChannelKey: Task<OpenedChannel, Error>] = [:]

    /// Resolves a charge of `amount` against `key`, opening the channel via `open` on the
    /// first charge and vouchering against the open channel afterwards.
    ///
    /// - Parameters:
    ///   - key: the `(payee, token, escrow)` the charge is for.
    ///   - amount: the per-request charge amount, added to the running cumulative.
    ///   - open: builds + signs the open transaction (and returns the channel id); run at
    ///     most once per key while no channel is open, even under concurrent charges.
    /// - Returns: the ``ChannelOutcome`` to assemble the credential from.
    /// - Throws: ``TempoChannelMethodError/cumulativeOverflow`` if the running cumulative
    ///   would exceed `uint128`, or whatever `open` throws.
    func charge(
        _ key: ChannelKey,
        amount: ChannelAmount,
        open: @Sendable @escaping () async throws -> OpenedChannel
    ) async throws -> ChannelOutcome {
        while true {
            // A channel is being opened for this key by another charge: await its completion,
            // then loop. By the time it completes the opener has registered the entry and
            // cleared the slot (atomically, below), so the next iteration vouchers (or, if the
            // open failed, opens). `result` waits without rethrowing: the open's success or
            // failure belongs to the charge that started it (which surfaces it to its own
            // caller); this waiter only needs the completion barrier, so it discards the
            // outcome rather than swallowing a thrown error with `try?`.
            if let inflight = opens[key] {
                _ = await inflight.result
                continue
            }
            if let entry = entries[key] {
                guard let next = entry.cumulative.adding(amount) else {
                    throw TempoChannelMethodError.cumulativeOverflow
                }
                entries[key] = Entry(channelID: entry.channelID, cumulative: next)
                return .voucher(channelID: entry.channelID, cumulative: next)
            }
            // No channel and none opening: this charge opens it. The two checks above and
            // this set are one synchronous segment (no `await` between), so only one charge
            // reaches here per key. The task settles the slot as its final, actor-isolated
            // step on BOTH paths (`register` on success, `clearSlot` on failure) before it
            // completes, so any charge that awaited it sees a consistent state the instant
            // its await returns: an entry present (then it vouchers) or the slot clear (then
            // it opens). No continuation-ordering race between the opener and the waiters,
            // and no waiter busy-wait on a completed-but-failed task.
            let task = Task<OpenedChannel, Error> {
                do {
                    let opened = try await open()
                    await self.register(key, opened: opened, amount: amount)
                    return opened
                } catch {
                    await self.clearSlot(key)
                    throw error
                }
            }
            opens[key] = task
            let opened = try await task.value
            return .open(
                channelID: opened.channelID, cumulative: amount, transaction: opened.transaction
            )
        }
    }

    /// Records a freshly opened channel and clears its in-flight slot, atomically on the
    /// actor (no `await` inside): the entry is set before the slot is cleared, so an
    /// observer that sees the slot clear also sees the entry.
    private func register(_ key: ChannelKey, opened: OpenedChannel, amount: ChannelAmount) {
        entries[key] = Entry(channelID: opened.channelID, cumulative: amount)
        opens[key] = nil
    }

    /// Clears a failed open's in-flight slot. No other charge can have replaced it: while
    /// this task ran, `opens[key]` held it (concurrent charges awaited it rather than
    /// opening), so clearing it cannot clobber a newer opener. A waiter that awaited this
    /// task sees the slot clear (and no entry) when its await returns, and opens afresh.
    private func clearSlot(_ key: ChannelKey) {
        opens[key] = nil
    }

    /// The open channel's id + latest cumulative for `key`, or nil if none is open. Used by
    /// topUp (it tops up the existing channel without changing the cumulative).
    func openChannel(_ key: ChannelKey) -> (channelID: Data, cumulative: ChannelAmount)? {
        entries[key].map { ($0.channelID, $0.cumulative) }
    }

    /// Removes and returns the open channel for `key`. Used by close: once the channel is
    /// settled on-chain, a later charge to the same key must open a fresh channel rather than
    /// voucher against the closed one.
    func removeChannel(_ key: ChannelKey) -> (channelID: Data, cumulative: ChannelAmount)? {
        guard let entry = entries[key] else { return nil }
        entries[key] = nil
        return (entry.channelID, entry.cumulative)
    }
}
