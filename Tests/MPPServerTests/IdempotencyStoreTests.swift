import Foundation
import HTTPTypes
import Testing
@testable import MPPServer

private extension IdempotencyOutcome {
    var isProceed: Bool {
        if case .proceed = self { true } else { false }
    }

    var isInProgress: Bool {
        if case .inProgress = self { true } else { false }
    }

    var replayed: IdempotentResponse? {
        if case let .replay(rec) = self { rec } else { nil }
    }
}

@Suite("InMemoryIdempotencyStore")
struct IdempotencyStoreTests {
    private func response(_ code: Int) -> IdempotentResponse {
        IdempotentResponse(
            response: HTTPResponse(status: .init(code: code)), body: Data("b\(code)".utf8)
        )
    }

    @Test("first begin proceeds; a held key is inProgress; a completed key replays")
    func lifecycle() async {
        let store = InMemoryIdempotencyStore()
        #expect(await store.begin("k").isProceed)
        #expect(await store.begin("k").isInProgress)
        await store.complete("k", response: response(200))
        #expect(await store.begin("k").replayed?.response.status.code == 200)
    }

    @Test("release frees an in-progress key for a later claim")
    func releaseFreesKey() async {
        let store = InMemoryIdempotencyStore()
        _ = await store.begin("k") // proceed (now in progress)
        await store.release("k") // unsettled: free it
        #expect(await store.begin("k").isProceed)
    }

    @Test("release never erases a recorded response")
    func releaseKeepsCompleted() async {
        let store = InMemoryIdempotencyStore()
        _ = await store.begin("k")
        await store.complete("k", response: response(201))
        await store.release("k") // a no-op on a completed key
        #expect(await store.begin("k").replayed?.response.status.code == 201)
    }
}
