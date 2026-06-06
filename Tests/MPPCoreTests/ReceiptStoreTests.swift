import Foundation
import MPPCore
import Testing

@Suite("InMemoryReceiptStore")
struct ReceiptStoreTests {
    private func receipt(_ reference: String) throws -> Receipt {
        try Receipt(
            method: MethodName("tempo"),
            timestamp: RFC3339DateTime(date: Date(timeIntervalSince1970: 1)),
            reference: reference
        )
    }

    @Test("records receipts in record order")
    func recordsInOrder() async throws {
        let store = InMemoryReceiptStore()
        let first = try receipt("a")
        let second = try receipt("b")
        await store.record(first)
        await store.record(second)
        let references = await store.receipts.map(\.reference)
        #expect(references == ["a", "b"])
    }

    @Test("a fresh store is empty")
    func emptyInitially() async {
        #expect(await InMemoryReceiptStore().receipts.isEmpty)
    }
}
