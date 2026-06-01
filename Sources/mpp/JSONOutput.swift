import Foundation
import MPPCore

/// The `--json` result envelope written to stdout. In JSON mode it is the ONLY thing on stdout
/// (progress and errors go to stderr), so a parent process - for example an app invoking `mpp` as a
/// subprocess - can parse the outcome (status, receipt reference, error code) cleanly.
struct JSONOutput: Encodable {
    let succeeded: Bool
    let status: Int
    var body: String?
    var receipt: ReceiptJSON?
    var error: ErrorJSON?

    enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case status, body, receipt, error
    }

    struct ReceiptJSON: Encodable {
        let method: String
        let reference: String
        let timestamp: String
    }

    struct ErrorJSON: Encodable {
        let code: String
        let exitCode: Int32
    }

    /// Encodes the receipt's display facts (never any secret) for the envelope.
    static func make(_ receipt: Receipt?) -> ReceiptJSON? {
        guard let receipt else { return nil }
        return ReceiptJSON(
            method: receipt.method.rawValue,
            reference: receipt.reference,
            timestamp: receipt.timestamp.rawValue
        )
    }

    /// Encodes and prints the envelope to stdout.
    func emit() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        print(text)
    }
}
