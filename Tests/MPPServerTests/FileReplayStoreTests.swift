import Foundation
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §11.3 / §11.5 (single-use challenge ids) and
// tempoxyz/mpp advanced/security.mdx "Prevent replay in production" (replay
// protection must survive a restart, not live in process-local memory).
@Suite("FileReplayStore")
final class FileReplayStoreTests: Sendable {
    /// A per-test temp root, removed wholesale in `deinit` so no test leaves
    /// directories behind in `/tmp` (Swift Testing makes a fresh instance per
    /// test, so each `deinit` cleans exactly that test's directories).
    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-replay-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A directory path under the test root; not pre-created so the store owns it.
    private func makeDirectoryURL() -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A fixed reference instant used by every store, so behavior never depends
    /// on the wall clock (CONTRIBUTING.md: inject the clock in testable paths).
    private static let reference = Date(timeIntervalSince1970: 1_700_000_000)

    /// A clock pinned to a fixed instant.
    private func fixedClock(_ date: Date = reference) -> @Sendable () -> Date {
        { date }
    }

    private func makeStore(
        retention: Duration = .seconds(3600),
        at directory: URL? = nil
    ) throws -> FileReplayStore {
        try FileReplayStore(
            directoryURL: directory ?? makeDirectoryURL(),
            retention: retention,
            now: fixedClock()
        )
    }

    @Test("first consume of an id wins; the second is a replay")
    func firstWins() async throws {
        let store = try makeStore()
        #expect(await store.consume("challenge-1"))
        #expect(await !store.consume("challenge-1"))
    }

    @Test("distinct ids are each accepted")
    func distinctIDsAccepted() async throws {
        let store = try makeStore()
        #expect(await store.consume("a"))
        #expect(await store.consume("b"))
    }

    @Test("ids are matched verbatim: case-sensitive, never normalized")
    func idsAreCaseSensitive() async throws {
        let store = try makeStore()
        #expect(await store.consume("Challenge-1"))
        #expect(await store.consume("challenge-1"))
    }

    @Test("the empty string is a valid single-use id")
    func emptyIDConsumable() async throws {
        let store = try makeStore()
        #expect(await store.consume(""))
        #expect(await !store.consume(""))
    }

    @Test("ids that a char-by-char sanitizer would conflate stay distinct")
    func collisionResistantFilenames() async throws {
        // A naive "replace non-alphanumerics with _" key->file scheme maps both
        // of these to the same file; for a replay store that would reject the
        // second id as a false replay. Hashed filenames keep them distinct.
        let store = try makeStore()
        #expect(await store.consume("a/b"))
        #expect(await store.consume("a_b"))
        #expect(await !store.consume("a/b"))
        #expect(await !store.consume("a_b"))
    }

    @Test("a consumed id is still a replay through a fresh store on the same directory")
    func durableAcrossRestart() async throws {
        let directory = makeDirectoryURL()
        let first = try makeStore(at: directory)
        #expect(await first.consume("persisted"))

        // A new instance models a process restart: the record is on disk.
        let second = try makeStore(at: directory)
        #expect(await !second.consume("persisted"))
    }

    @Test("an id consumed within the retention window is still remembered")
    func remembersWithinRetention() async throws {
        let directory = makeDirectoryURL()
        let early = try FileReplayStore(
            directoryURL: directory, retention: .seconds(3600), now: fixedClock()
        )
        #expect(await early.consume("x"))

        // 30 minutes later, well inside the 1-hour window: still a replay.
        let later = try FileReplayStore(
            directoryURL: directory,
            retention: .seconds(3600),
            now: fixedClock(Self.reference.addingTimeInterval(1800))
        )
        #expect(await !later.consume("x"))
    }

    @Test("an id past the retention window is pruned and consumable again")
    func prunesAfterRetention() async throws {
        let directory = makeDirectoryURL()
        let early = try FileReplayStore(
            directoryURL: directory, retention: .seconds(60), now: fixedClock()
        )
        #expect(await early.consume("x"))

        // Two minutes later, past the 60s window: init prunes the record, so the
        // id is no longer a replay. (An expired challenge is rejected upstream,
        // so reissuing the id cannot enable a real replay.)
        let later = try FileReplayStore(
            directoryURL: directory,
            retention: .seconds(60),
            now: fixedClock(Self.reference.addingTimeInterval(120))
        )
        #expect(await later.consume("x"))
    }

    @Test("a record with unreadable contents is conservatively kept (still a replay)")
    func unparsableRecordStillBlocks() async throws {
        // Models a crash that left a record file without a valid timestamp: the
        // store must not treat it as absent and accept a replay.
        let directory = makeDirectoryURL()
        let store = try makeStore(retention: .seconds(60), at: directory)
        #expect(await store.consume("x"))

        // Corrupt the on-disk record, then reopen: prune cannot parse it, leaves
        // it, and the exclusive-create still sees the file -> replay.
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let record = try #require(entries.first)
        try Data("garbage".utf8).write(to: record)

        let reopened = try makeStore(retention: .seconds(60), at: directory)
        #expect(await !reopened.consume("x"))
    }

    @Test("an empty crashed-mid-write record is reaped once older than retention")
    func emptyRecordPrunedWhenOld() throws {
        // A 0-byte file models a crash between the exclusive create and the
        // timestamp write: the id was never accepted, so once it ages past the
        // window it should be reaped, not leaked forever.
        let directory = makeDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dead = directory.appendingPathComponent("deadbeef", isDirectory: false)
        FileManager.default.createFile(atPath: dead.path, contents: Data())
        try FileManager.default.setAttributes(
            [.modificationDate: Self.reference.addingTimeInterval(-1000)], ofItemAtPath: dead.path
        )

        // Opening with a 60s window and the reference clock prunes on load.
        _ = try FileReplayStore(directoryURL: directory, retention: .seconds(60), now: fixedClock())
        #expect(!FileManager.default.fileExists(atPath: dead.path))
    }

    @Test("an empty record within the retention window is kept (could be in-flight)")
    func emptyRecordKeptWhenFresh() throws {
        let directory = makeDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fresh = directory.appendingPathComponent("deadbeef", isDirectory: false)
        FileManager.default.createFile(atPath: fresh.path, contents: Data())
        try FileManager.default.setAttributes(
            [.modificationDate: Self.reference], ofItemAtPath: fresh.path
        )

        _ = try FileReplayStore(directoryURL: directory, retention: .seconds(60), now: fixedClock())
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("under concurrent consume of one id, exactly one caller wins")
    func concurrentSingleWinner() async throws {
        let store = try makeStore()
        let attempts = 100
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< attempts {
                group.addTask { await store.consume("contended") }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        // The actor serializes consume and O_EXCL makes the create atomic, so
        // exactly one racing caller records the first use.
        #expect(wins == 1)
    }

    @Test("concurrent consume of distinct ids all win")
    func concurrentDistinctAllWin() async throws {
        let store = try makeStore()
        let count = 100
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0 ..< count {
                group.addTask { await store.consume("id-\(index)") }
            }
            var total = 0
            for await won in group where won {
                total += 1
            }
            return total
        }
        #expect(wins == count)
    }

    @Test("init throws when the backing directory cannot be created")
    func initThrowsOnUnusableDirectory() throws {
        // Root the store under a regular file: createDirectory cannot succeed.
        let file = root.appendingPathComponent("not-a-dir")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let nested = file.appendingPathComponent("store", isDirectory: true)
        #expect(throws: FileReplayStore.StoreError.self) {
            _ = try FileReplayStore(
                directoryURL: nested,
                retention: .seconds(60),
                now: fixedClock()
            )
        }
    }

    @Test("init rejects a non-positive retention window", arguments: [Duration.zero, .seconds(-1)])
    func initRejectsNonPositiveRetention(retention: Duration) {
        // A zero or negative window expires every record immediately, which
        // would let prune delete it and the same id be consumed again. The store
        // must refuse to open rather than silently void replay protection.
        #expect(throws: FileReplayStore.StoreError.nonPositiveRetention) {
            _ = try FileReplayStore(
                directoryURL: makeDirectoryURL(), retention: retention, now: fixedClock()
            )
        }
    }
}
