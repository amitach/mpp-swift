import Crypto
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A durable, single-host ``ReplayStore`` that records each consumed challenge id
/// as a file, so replay protection survives a process restart.
///
/// `draft-httpauth-payment-00` §11.3 / §11.5 makes each challenge single-use, and
/// `tempoxyz/mpp` `advanced/security.mdx` ("Prevent replay in production") requires
/// that replay protection "survive concurrency and multi-instance deployments" and
/// that a server "not rely on process-local memory for replay protection in
/// distributed deployments". ``InMemoryReplayStore`` loses every consumed id when
/// the process exits, so it cannot meet that bar; this store persists them.
///
/// ## How a consume is recorded
///
/// Each id maps to one file named `SHA256(id)` (hex) in `directoryURL`. The first
/// use of an id is the atomic, exclusive creation of that file
/// (`O_CREAT | O_EXCL`): on a single host, and across processes that share the
/// directory, exactly one creator wins, so the check-and-record is atomic without
/// an in-process lock. A second consume of the same id finds the file already
/// present and is rejected as a replay. After creating the file the store writes
/// the consume time into it and `fsync`s the file and its directory, so a crash
/// immediately after ``consume(_:)`` returns `true` cannot lose the record.
///
/// ## Bounding growth
///
/// Records older than `retention` are pruned (on init and periodically): an
/// expired challenge is already rejected upstream, so dropping its id can never
/// enable a replay. `retention` MUST exceed the longest challenge lifetime the
/// server issues, or an id could be pruned while its challenge is still valid.
///
/// ## Scope: single shared filesystem
///
/// This store serves a single host (or instances sharing one filesystem). A
/// fleet that does not share a filesystem should implement ``ReplayStore`` against
/// a shared backend with atomic create semantics (Redis `SET NX`, a database
/// unique constraint, etc.); the protocol is that plug-in point.
public actor FileReplayStore: ReplayStore {
    /// A reason the store could not be opened.
    public enum StoreError: Error, Equatable {
        /// The backing directory could not be created or is not usable.
        case directoryUnavailable(path: String)
        /// `retention` was not strictly positive. A zero or negative window
        /// expires every record immediately, so prune would delete it and the
        /// same id would be consumable again: replay protection would be void.
        case nonPositiveRetention
    }

    private let directoryURL: URL
    private let retentionSeconds: Double
    private let now: @Sendable () -> Date
    /// Prune expired records once every this many consumes (amortizes the scan).
    private let pruneInterval: Int
    private var consumesSincePrune = 0

    /// Opens (creating if needed) a durable replay store rooted at `directoryURL`.
    ///
    /// - Parameters:
    ///   - directoryURL: A directory the process owns; created with `0o700` if
    ///     absent. All replay records live here and nothing else should.
    ///   - retention: How long a consumed id is remembered. MUST exceed the
    ///     longest challenge lifetime the server issues (see the type doc).
    ///   - pruneInterval: How many consumes between amortized expiry sweeps; a
    ///     tuning knob with a sensible default. Clamped to at least 1.
    ///   - now: The clock, injected for deterministic tests. Defaults to the
    ///     system clock.
    /// - Throws: ``StoreError/nonPositiveRetention`` if `retention <= 0`;
    ///   ``StoreError/directoryUnavailable(path:)`` if the directory cannot be
    ///   created.
    public init(
        directoryURL: URL,
        retention: Duration,
        pruneInterval: Int = 256,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws(StoreError) {
        guard retention > .zero else { throw StoreError.nonPositiveRetention }
        self.directoryURL = directoryURL
        retentionSeconds = Self.seconds(of: retention)
        self.pruneInterval = max(1, pruneInterval)
        self.now = now
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StoreError.directoryUnavailable(path: directoryURL.path)
        }
        Self.prune(in: directoryURL, retentionSeconds: retentionSeconds, asOf: now())
    }

    public func consume(_ id: String) -> Bool {
        // Decide for THIS id first, so its verdict can never depend on a prune in
        // the same call (a prune that removed this id's record before recording
        // would let it be consumed twice). Expiry cleanup of OTHER ids is an
        // amortized housekeeping step that runs afterwards.
        let firstUse = record(id)
        consumesSincePrune += 1
        if consumesSincePrune >= pruneInterval {
            consumesSincePrune = 0
            Self.prune(in: directoryURL, retentionSeconds: retentionSeconds, asOf: now())
        }
        return firstUse
    }

    // MARK: - Recording

    /// Atomically creates the record file for `id`. Returns `true` on the first
    /// use (the exclusive create succeeded and was made durable), `false` on a
    /// replay (the file already existed) or any error (fail closed: never accept
    /// a payment we cannot prove un-replayed).
    private func record(_ id: String) -> Bool {
        let path = fileURL(for: id).path
        let descriptor = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard descriptor >= 0 else {
            // EEXIST is a replay; any other errno fails closed. Both reject.
            return false
        }
        let stamp = "\(now().timeIntervalSince1970)\n"
        let durable = writeAndSync(stamp, to: descriptor) && syncDirectory()
        close(descriptor)
        guard durable else {
            // Could not durably record the consume (write, file fsync, or the
            // directory-entry fsync failed): fail closed and remove the marker so
            // a fresh challenge for this id is not blocked. Returning true here
            // would risk a crash dropping a record we already accepted.
            _ = path.withCString { unlink($0) }
            return false
        }
        return true
    }

    /// Writes `content` in full and flushes it to durable storage. Returns
    /// whether both succeeded. Retries on `EINTR` and on short writes (POSIX
    /// `write` may do either), so a signal does not spuriously fail the consume
    /// closed.
    private func writeAndSync(_ content: String, to descriptor: Int32) -> Bool {
        let bytes = Array(content.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            if written == 0 { return false } // no progress: avoid an infinite loop
            offset += written
        }
        return flush(descriptor)
    }

    /// Flushes `descriptor` to durable storage, retrying on `EINTR`.
    ///
    /// On Darwin plain `fsync` only reaches the drive's write cache, so this uses
    /// `F_FULLFSYNC` for true platter-level durability, falling back to `fsync`
    /// on a filesystem that does not support it. On Linux `fsync` already
    /// provides the durability guarantee.
    private func flush(_ descriptor: Int32) -> Bool {
        #if canImport(Darwin)
            while fcntl(descriptor, F_FULLFSYNC) == -1 {
                switch errno {
                case EINTR: continue
                case ENOTSUP, EINVAL: return fsyncRetrying(descriptor) // no F_FULLFSYNC here
                default: return false
                }
            }
            return true
        #else
            return fsyncRetrying(descriptor)
        #endif
    }

    private func fsyncRetrying(_ descriptor: Int32) -> Bool {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Flushes the directory entry so a newly created record survives a crash.
    /// Returns whether the flush succeeded; a failure must fail the consume
    /// closed, since the file could otherwise vanish on a crash.
    private func syncDirectory() -> Bool {
        let descriptor = directoryURL.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return false }
        let synced = flush(descriptor)
        close(descriptor)
        return synced
    }

    // MARK: - Pruning

    /// Removes records whose stored consume time is older than `retentionSeconds`.
    /// Static so the throwing, nonisolated init can prune on load; it reads no
    /// mutable actor state.
    private static func prune(in directory: URL, retentionSeconds: Double, asOf instant: Date) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries
            where isExpired(entry, retentionSeconds: retentionSeconds, asOf: instant) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// A record is expired when the consume time it stores is older than
    /// `retentionSeconds`. Files we cannot parse are left in place (conservative:
    /// never drop a record we are unsure about).
    private static func isExpired(
        _ entry: URL,
        retentionSeconds: Double,
        asOf instant: Date
    ) -> Bool {
        guard
            let raw = try? String(contentsOf: entry, encoding: .utf8),
            let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let consumedAt = Date(timeIntervalSince1970: seconds)
        return instant.timeIntervalSince(consumedAt) > retentionSeconds
    }

    private static func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func fileURL(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }
}
