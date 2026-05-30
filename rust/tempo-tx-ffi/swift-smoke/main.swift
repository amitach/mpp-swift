import Foundation

let golden = "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555555555555580b8e40d65c51dabababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0800780808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c"

let tx = try buildCloseTransaction(
    chainId: 42431, nonce: 7,
    maxFeePerGas: "1000000000", maxPriorityFeePerGas: "1000000", gasLimit: 100000,
    feeToken: nil,
    privateKey: Data(repeating: 0x11, count: 32),
    escrow: Data(repeating: 0x55, count: 20),
    channelId: Data(repeating: 0xAB, count: 32),
    cumulativeAmount: "1000",
    voucherSignature: Data(repeating: 0, count: 65)
)
let hex = tx.map { String(format: "%02x", $0) }.joined()
if hex == golden {
    print("FFI SMOKE TEST: PASS - Swift called Rust, got byte-identical 0x76 tx (\(tx.count) bytes)")
} else {
    print("FFI SMOKE TEST: FAIL"); print("got: \(hex)"); exit(1)
}
