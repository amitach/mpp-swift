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
    ///   - now: The clock, injected for deterministic tests. Defaults to the
    ///     system clock.
    /// - Throws: ``StoreError/directoryUnavailable(path:)`` if the directory
    ///   cannot be created.
    public init(
        directoryURL: URL,
        retention: Duration,
        pruneInterval: Int = 256,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws(StoreError) {
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
        consumesSincePrune += 1
        if consumesSincePrune >= pruneInterval {
            consumesSincePrune = 0
            Self.prune(in: directoryURL, retentionSeconds: retentionSeconds, asOf: now())
        }
        return record(id)
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
        let durable = writeAndSync(stamp, to: descriptor)
        close(descriptor)
        guard durable else {
            // Could not durably record the consume: fail closed and remove the
            // partial marker so a fresh challenge for this id is not blocked.
            _ = path.withCString { unlink($0) }
            return false
        }
        syncDirectory()
        return true
    }

    /// Writes `content` and flushes it to disk. Returns whether both succeeded.
    private func writeAndSync(_ content: String, to descriptor: Int32) -> Bool {
        let bytes = Array(content.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else { return false }
        return fsync(descriptor) == 0
    }

    /// Flushes the directory entry so a newly created record survives a crash.
    private func syncDirectory() {
        let descriptor = directoryURL.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    // MARK: - Pruning

    /// Removes records whose stored consume time is older than `retentionSeconds`.
    /// Static so the throwing, nonisolated init can prune on load; it reads no
    /// mutable actor state.
    private static func prune(in directory: URL, retentionSeconds: Double, asOf instant: Date) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
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
