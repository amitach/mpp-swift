import Foundation
import Testing
@testable import MPPKeccak

// Keccak-256 known-answer vectors. The empty-string and "abc" digests are the
// universally-published Keccak-256 values; the remaining vectors were generated
// with js-sha3 (cross-checked against those two anchors) and deliberately span
// the rate boundary (135 = one free pad byte, 136 = a full block forcing an
// extra padding block, 137 = multi-block) and a larger multi-block input, since
// those are the paths a sponge implementation gets wrong.
@Suite("Keccak256")
struct Keccak256Tests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func keccak(_ string: String) -> String {
        hex(Keccak256.hash(Data(string.utf8)))
    }

    @Test("empty string (the canonical anchor)")
    func empty() {
        #expect(keccak("") == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    @Test("short single-block inputs")
    func shortInputs() {
        #expect(keccak("abc") == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        #expect(keccak("hello") ==
            "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }

    @Test("rate boundary: 135, 136, 137 bytes (padding + first multi-block edge)")
    func rateBoundary() {
        #expect(keccak(String(repeating: "a", count: 135))
            == "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446")
        #expect(keccak(String(repeating: "a", count: 136))
            == "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e")
        #expect(keccak(String(repeating: "a", count: 137))
            == "d869f639c7046b4929fc92a4d988a8b22c55fbadb802c0c66ebcd484f1915f39")
    }

    @Test("multi-block input (300 bytes)")
    func multiBlock() {
        #expect(keccak(String(repeating: "x", count: 300))
            == "956875d0d3af4718863b89e475911881cebd1cd08cfe3c2fcd0890d29def1e37")
    }
}
