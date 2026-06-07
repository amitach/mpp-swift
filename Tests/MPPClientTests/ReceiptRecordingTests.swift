import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import Testing

// The optional ReceiptStore: a paid response's Payment-Receipt is recorded (best-effort) for a
// ledger / reconciliation trail; with no store, or no receipt, the flow is unchanged.
@Suite("PaymentClient receipt recording")
struct ReceiptRecordingTests {
    private func paidReceipt(method: MethodName) -> Receipt {
        Receipt(
            method: method,
            timestamp: RFC3339DateTime(date: Date(timeIntervalSince1970: 1)),
            reference: "tx_1"
        )
    }

    @Test("a paid response's receipt is recorded in the receipt store")
    func recordsReceipt() async throws {
        let method = try tempo()
        let chal = challenge(method: method)
        var paidHeaders = HTTPFields()
        paidHeaders[fieldName("Payment-Receipt")] = try paidReceipt(method: method).headerValue
        let transport = StubTransport([
            response(402, headers: [.wwwAuthenticate: chal.headerValue]),
            (HTTPResponse(status: .ok, headerFields: paidHeaders), Data()),
        ])
        let store = InMemoryReceiptStore()
        let client = PaymentClient(
            transport: transport, methods: [StubMethod(methodName: method)], receiptStore: store
        )
        _ = try await client.send(request())
        let references = await store.receipts.map(\.reference)
        #expect(references == ["tx_1"])
    }

    @Test("a paid response with no Payment-Receipt records nothing")
    func noReceiptNoRecord() async throws {
        let method = try tempo()
        let chal = challenge(method: method)
        let transport = StubTransport([
            response(402, headers: [.wwwAuthenticate: chal.headerValue]),
            response(200),
        ])
        let store = InMemoryReceiptStore()
        let client = PaymentClient(
            transport: transport, methods: [StubMethod(methodName: method)], receiptStore: store
        )
        _ = try await client.send(request())
        #expect(await store.receipts.isEmpty)
    }
}
