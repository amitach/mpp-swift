import Foundation
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §11.3 / §11.5 (single-use challenge ids) and
// tempoxyz/mpp advanced/security.mdx "Prevent replay in production" (replay
// protection must survive a restart, not live in process-local memory).
@Suite("FileReplayStore")
struct FileReplayStoreTests {
    /// A directory path the store will create; not pre-created so init owns it.
    private func makeDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-replay-\(UUID().uuidString)", isDirectory: true)
    }

    /// A clock pinned to a fixed instant.
    private func fixedClock(_ date: Date) -> @Sendable () -> Date {
        { date }
    }

    @Test("first consume of an id wins; the second is a replay")
    func firstWins() async throws {
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
        #expect(await store.consume("challenge-1"))
        #expect(await !store.consume("challenge-1"))
    }

    @Test("distinct ids are each accepted")
    func distinctIDsAccepted() async throws {
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
        #expect(await store.consume("a"))
        #expect(await store.consume("b"))
    }

    @Test("ids are matched verbatim: case-sensitive, never normalized")
    func idsAreCaseSensitive() async throws {
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
        #expect(await store.consume("Challenge-1"))
        #expect(await store.consume("challenge-1"))
    }

    @Test("the empty string is a valid single-use id")
    func emptyIDConsumable() async throws {
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
        #expect(await store.consume(""))
        #expect(await !store.consume(""))
    }

    @Test("ids that a char-by-char sanitizer would conflate stay distinct")
    func collisionResistantFilenames() async throws {
        // A naive "replace non-alphanumerics with _" key->file scheme maps both
        // of these to the same file; for a replay store that would reject the
        // second id as a false replay. Hashed filenames keep them distinct.
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
        #expect(await store.consume("a/b"))
        #expect(await store.consume("a_b"))
        #expect(await !store.consume("a/b"))
        #expect(await !store.consume("a_b"))
    }

    @Test("a consumed id is still a replay through a fresh store on the same directory")
    func durableAcrossRestart() async throws {
        let directory = makeDirectoryURL()
        let first = try FileReplayStore(directoryURL: directory, retention: .seconds(3600))
        #expect(await first.consume("persisted"))

        // A new instance models a process restart: the record is on disk.
        let second = try FileReplayStore(directoryURL: directory, retention: .seconds(3600))
        #expect(await !second.consume("persisted"))
    }

    @Test("an id consumed within the retention window is still remembered")
    func remembersWithinRetention() async throws {
        let directory = makeDirectoryURL()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let early = try FileReplayStore(
            directoryURL: directory, retention: .seconds(3600), now: fixedClock(start)
        )
        #expect(await early.consume("x"))

        // 30 minutes later, well inside the 1-hour window: still a replay.
        let later = try FileReplayStore(
            directoryURL: directory,
            retention: .seconds(3600),
            now: fixedClock(start.addingTimeInterval(1800))
        )
        #expect(await !later.consume("x"))
    }

    @Test("an id past the retention window is pruned and consumable again")
    func prunesAfterRetention() async throws {
        let directory = makeDirectoryURL()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let early = try FileReplayStore(
            directoryURL: directory, retention: .seconds(60), now: fixedClock(start)
        )
        #expect(await early.consume("x"))

        // Two minutes later, past the 60s window: init prunes the record, so the
        // id is no longer a replay. (An expired challenge is rejected upstream,
        // so reissuing the id cannot enable a real replay.)
        let later = try FileReplayStore(
            directoryURL: directory,
            retention: .seconds(60),
            now: fixedClock(start.addingTimeInterval(120))
        )
        #expect(await later.consume("x"))
    }

    @Test("a record with unreadable contents is conservatively kept (still a replay)")
    func unparsableRecordStillBlocks() async throws {
        // Models a crash that left a record file without a valid timestamp: the
        // store must not treat it as absent and accept a replay.
        let directory = makeDirectoryURL()
        let store = try FileReplayStore(directoryURL: directory, retention: .seconds(60))
        #expect(await store.consume("x"))

        // Corrupt the on-disk record, then reopen: prune cannot parse it, leaves
        // it, and the exclusive-create still sees the file -> replay.
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        let record = try #require(entries.first)
        try Data("garbage".utf8).write(to: record)

        let reopened = try FileReplayStore(directoryURL: directory, retention: .seconds(60))
        #expect(await !reopened.consume("x"))
    }

    @Test("under concurrent consume of one id, exactly one caller wins")
    func concurrentSingleWinner() async throws {
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
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
        let store = try FileReplayStore(directoryURL: makeDirectoryURL(), retention: .seconds(3600))
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
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-replay-file-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }

        let nested = file.appendingPathComponent("store", isDirectory: true)
        #expect(throws: FileReplayStore.StoreError.self) {
            _ = try FileReplayStore(directoryURL: nested, retention: .seconds(60))
        }
    }
}
