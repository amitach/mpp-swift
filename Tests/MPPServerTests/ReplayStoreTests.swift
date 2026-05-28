import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §11.3 / §11.5 — single-use challenge ids;
// consume is the atomic serialization point (first use wins, replays rejected).
@Suite("InMemoryReplayStore")
struct ReplayStoreTests {
    @Test("first consume of an id wins; the second is a replay")
    func firstWins() async {
        let store = InMemoryReplayStore()
        #expect(await store.consume("challenge-1"))
        #expect(await !store.consume("challenge-1"))
    }

    @Test("distinct ids are each accepted")
    func distinctIDsAccepted() async {
        let store = InMemoryReplayStore()
        #expect(await store.consume("a"))
        #expect(await store.consume("b"))
    }

    @Test("under concurrent consume of one id, exactly one caller wins")
    func concurrentSingleWinner() async {
        let store = InMemoryReplayStore()
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
        // The actor serializes consume, so exactly one of the racing callers
        // sees the first insert.
        #expect(wins == 1)
    }

    @Test("concurrent consume of distinct ids all win")
    func concurrentDistinctAllWin() async {
        let store = InMemoryReplayStore()
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
}
