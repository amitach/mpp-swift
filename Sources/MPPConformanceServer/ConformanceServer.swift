import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer

#if MPP_TEMPO_FFI_ENABLED
    import MPPTempoFFI
#endif

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

// A minimal, dev-only HTTP/1.1 server that exposes one zero-amount tempo/charge
// endpoint backed by MPPServerMiddleware + TempoProofVerifier, so a foreign client
// (the mppx reference SDK) can pay our server over a real socket and have its proof
// verified by our code. Raw POSIX sockets, no new dependency; not shipped (an
// executable target with no product). Serves one request per connection then closes.

// The requested port (PORT=0 asks the OS for an ephemeral one). UInt16's failable
// string initializer returns nil for a non-numeric or out-of-range PORT, so a bad
// value falls back to the default rather than trapping.
private let requestedPort = ProcessInfo.processInfo.environment["PORT"]
    .flatMap(UInt16.init) ?? 8799
// Moderato testnet chain id, put in the challenge so a Tempo client signs for it.
private let chainId: UInt64 = 42431
private let secret = Data("mpp-swift-reverse-conformance-secret-key-0123456789".utf8)
// CONFORMANCE_VERBOSE=1 logs the challenge issued and the credential verified, so a
// run shows the real data crossing the wire (useful for debugging interop).
private let verbose = ProcessInfo.processInfo.environment["CONFORMANCE_VERBOSE"] == "1"

private func log(_ message: @autoclosure () -> String) {
    // fflush(nil) flushes all streams without referencing the global `stdout` var,
    // which is not concurrency-safe under Swift 6 on Glibc.
    if verbose { print(message()); fflush(nil) }
}

private func makeMiddleware() throws -> MPPServerMiddleware {
    let signer = ChallengeSigner(secret: secret)
    let binding = try RouteBinding(
        realm: "127.0.0.1", method: MethodName("tempo"), intent: .charge
    )
    let request = EncodedJSON(json: .object([
        "amount": .string("0"),
        "methodDetails": .object(["chainId": .integer(Int64(chainId))]),
    ]))
    return MPPServerMiddleware(
        minter: ChallengeMinter(signer: signer),
        verifier: PaymentVerifier(
            signer: signer, replayStore: InMemoryReplayStore(), methods: [TempoProofVerifier()]
        ),
        binding: binding,
        request: request
    ) { event in
        switch event {
        case let .challengeIssued(challenge):
            log("[server] issued 402  id=\(challenge.id)")
            log("[server]              realm=\(challenge.realm) method=\(challenge.method.rawValue)"
                + " intent=\(challenge.intent.rawValue)")
            log("[server]              request(b64url)=\(challenge.request.rawValue)")
        case let .paymentVerified(verified):
            log("[server] VERIFIED     source=\(verified.credential.source ?? "nil")")
        case let .paymentRejected(rejection):
            log("[server] rejected     \(rejection)")
        }
    }
}

#if MPP_TEMPO_FFI_ENABLED
    // Reverse session conformance (live on Moderato). The mppx CLIENT opens a channel to
    // our recipient, vouchers, and closes; our SessionMethod relays the open, accepts the
    // vouchers, and settles the close on-chain with the faucet-funded operator key. Gated
    // on the FFI (the close builder) and on CONFORMANCE_OPERATOR_KEY being set.
    private let moderatoRPCURL = "https://rpc.moderato.tempo.xyz"
    private let sessionEscrowHex = "0xe1c4d3dce17bc111181ddf716f75bae49e61a336"
    private let sessionTokenHex = "0x20c0000000000000000000000000000000000000"

    private enum SessionConfigError: Error { case badOperatorKey }

    /// A `ReplayStore` that never consumes: a session reuses ONE challenge across
    /// open/voucher/close (the reference `sessionManager` does this), and its anti-replay is
    /// the monotonic cumulative the channel store enforces, not one-time challenge use. The
    /// default one-time `InMemoryReplayStore` is correct only for one-shot proof/charge and
    /// would reject every voucher after the open.
    private struct ReusableReplayStore: ReplayStore {
        func consume(_: String) async -> Bool {
            true
        }
    }

    /// Resolves the on-chain relay/settle provider and the operator (payee) address from the
    /// faucet-funded operator key, or nil if no key is configured (proof-only run).
    private func makeSessionProvider()
        async throws -> (provider: RPCChannelStateProvider, payee: EthereumAddress)? {
        guard let keyHex = ProcessInfo.processInfo.environment["CONFORMANCE_OPERATOR_KEY"],
              let keyData = Data(hexPrefixed: keyHex)
        else { return nil }
        let operatorSigner = try Secp256k1Signer(privateKey: keyData)
        guard let payee = EthereumAddress(uncompressedPublicKey: operatorSigner.publicKey),
              let rpcURL = URL(string: moderatoRPCURL)
        else { throw SessionConfigError.badOperatorKey }
        let rpc = try EVMRPC(transport: URLSessionTransport(), url: rpcURL)
        let gasPrice = try await rpc.gasPrice()
        let builder = FFITempoTxBuilder(
            signingKey: keyData,
            fee: TempoFeeParameters(
                maxFeePerGas: String(gasPrice * 2),
                maxPriorityFeePerGas: "0",
                gasLimit: 2_000_000,
                feeToken: nil
            ),
            nonceProvider: { try await rpc.transactionCount($0) }
        )
        return (RPCChannelStateProvider(rpc: rpc, closeTxBuilder: builder), payee)
    }

    /// Builds the session middleware, or nil if no operator key is configured (proof-only).
    private func makeSessionMiddleware() async throws -> MPPServerMiddleware? {
        guard let (provider, payee) = try await makeSessionProvider() else { return nil }
        let sessionMethod = SessionMethod(
            provider: provider, store: InMemoryChannelStore(), defaultChainID: chainId
        )
        let signer = ChallengeSigner(secret: secret)
        let binding = try RouteBinding(
            realm: "127.0.0.1", method: MethodName("tempo"), intent: .session
        )
        // The session 402 the mppx client opens against: amount + payee (our operator) +
        // currency + a top-level suggestedDeposit + methodDetails.{chainId, escrowContract}.
        let request = EncodedJSON(json: .object([
            "amount": .string("1"),
            "recipient": .string(payee.checksummed),
            "currency": .string(sessionTokenHex),
            "suggestedDeposit": .string("1000"),
            "methodDetails": .object([
                "chainId": .integer(Int64(chainId)),
                "escrowContract": .string(sessionEscrowHex),
            ]),
        ]))
        return MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            verifier: PaymentVerifier(
                signer: signer, replayStore: ReusableReplayStore(), methods: [sessionMethod]
            ),
            binding: binding,
            request: request
        ) { event in
            switch event {
            case let .challengeIssued(challenge):
                log("[server] issued 402 (session) id=\(challenge.id)")
            case let .paymentVerified(verified):
                log("[server] VERIFIED (session) source=\(verified.credential.source ?? "nil")")
            case let .paymentRejected(rejection):
                log("[server] rejected (session) \(rejection)")
            }
        }
    }
#endif

/// Reads up to 4096 more bytes from `descriptor` into `buffer` (one syscall), or
/// returns false at EOF/error.
private func readMore(_ descriptor: Int32, into buffer: inout Data) -> Bool {
    var chunk = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(descriptor, &chunk, chunk.count)
    guard bytesRead > 0 else { return false }
    buffer.append(contentsOf: chunk[0 ..< bytesRead])
    return true
}

/// The parsed request line + headers of an HTTP request.
private struct Head {
    let method: String
    let target: String
    let fields: HTTPFields
    let host: String
    let contentLength: Int
}

/// Parses the header block into the request line method/target plus the fields,
/// host, and declared content length.
private func parseHead(_ text: String) -> Head? {
    let lines = text.components(separatedBy: "\r\n")
    let requestLine = lines.first?.components(separatedBy: " ") ?? []
    guard requestLine.count >= 2 else { return nil }

    var fields = HTTPFields()
    var host = ""
    var contentLength = 0
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if name.lowercased() == "host" { host = value }
        if name.lowercased() == "content-length" { contentLength = Int(value) ?? 0 }
        if let fieldName = HTTPField.Name(name) { fields[fieldName] = value }
    }
    return Head(
        method: requestLine[0], target: requestLine[1],
        fields: fields, host: host, contentLength: contentLength
    )
}

/// Reads a full HTTP/1.1 request: the request line, headers, and a body sized by
/// `Content-Length`. Returns the parsed `HTTPRequest` and body, or nil.
private func readRequest(_ descriptor: Int32) -> (HTTPRequest, Data)? {
    let terminator = Data("\r\n\r\n".utf8)
    var buffer = Data()
    while buffer.range(of: terminator) == nil {
        guard readMore(descriptor, into: &buffer) else { return nil }
    }
    guard let headerEnd = buffer.range(of: terminator),
          let text = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8),
          let head = parseHead(text)
    else { return nil }

    var body = Data(buffer[headerEnd.upperBound...])
    while body.count < head.contentLength {
        guard readMore(descriptor, into: &body) else { break }
    }

    var request = HTTPRequest(
        method: HTTPRequest.Method(head.method) ?? .get,
        scheme: "http",
        authority: head.host.isEmpty ? "127.0.0.1" : head.host,
        path: head.target
    )
    request.headerFields = head.fields
    return (request, body)
}

/// Serializes `(response, body)` as an HTTP/1.1 message and writes it to `descriptor`.
private func writeResponse(_ response: HTTPResponse, _ body: Data, to descriptor: Int32) {
    var head = "HTTP/1.1 \(response.status.code) \(response.status.reasonPhrase)\r\n"
    for field in response.headerFields where field.name != .contentLength {
        head += "\(field.name.canonicalName): \(field.value)\r\n"
    }
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    out.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        // Loop over short writes: write() may return fewer bytes than requested.
        var offset = 0
        while offset < raw.count {
            let written = write(descriptor, base + offset, raw.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
}

/// Logs what the server received on a request: the method/path, and (when a
/// credential is present) the decoded challenge id, source DID, and proof payload.
private func logIncoming(_ request: HTTPRequest) {
    guard verbose else { return }
    guard let auth = request.headerFields[.authorization] else {
        log("[server] <- \(request.method.rawValue) \(request.path ?? "") (no credential)")
        return
    }
    log("[server] <- \(request.method.rawValue) \(request.path ?? "") (Authorization: Payment)")
    guard let credential = try? Credential(headerValue: auth) else { return }
    log("[server]    credential.challenge.id = \(credential.challenge.id)")
    log("[server]    credential.source       = \(credential.source ?? "nil")")
    if case let .string(type)? = credential.payload["type"] {
        log("[server]    credential.payload.type = \(type)")
    }
    if case let .string(signature)? = credential.payload["signature"] {
        log("[server]    credential.payload.signature = \(signature)")
    }
}

/// Binds + listens on `127.0.0.1:requestedPort` (PORT=0 -> an OS-assigned ephemeral port)
/// and returns the listening socket and the actually-bound port. Traps on failure (this is
/// a dev-only tool).
private func bindListener() -> (descriptor: Int32, port: UInt16) {
    let listener = socket(AF_INET, sockStreamType, 0)
    guard listener >= 0 else { fatalError("socket() failed") }
    var reuse: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = requestedPort.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(listener, 16) == 0 else { fatalError("bind/listen failed") }

    var local = sockaddr_in()
    var localLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &local) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &localLen)
        }
    }
    return (listener, UInt16(bigEndian: local.sin_port))
}

@main
enum ConformanceServer {
    static func main() async throws {
        // A client that disconnects mid-write would otherwise raise SIGPIPE and kill
        // the process; ignore it and let the write fail (handled by the write loop).
        signal(SIGPIPE, SIG_IGN)
        let proofMiddleware = try makeMiddleware()
        #if MPP_TEMPO_FFI_ENABLED
            let sessionMiddleware = try await makeSessionMiddleware()
        #endif

        let (listener, boundPort) = bindListener()
        // The run script parses this line to learn the actually-bound port (PORT=0 asks the
        // OS for an ephemeral one).
        print("reverse-conformance-server listening http://127.0.0.1:\(boundPort)/proof")
        fflush(nil)

        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { continue }
            defer { close(connection) }
            guard let (request, body) = readRequest(connection) else { continue }
            logIncoming(request)
            let serve: @Sendable (HTTPRequest, MPPVerified) async
                -> (HTTPResponse, Data) = { _, _ in
                    (HTTPResponse(status: .ok), Data(#"{"ok":true,"paid":true}"#.utf8))
                }
            // Route by path: /session goes to the (FFI-gated) session middleware when it is
            // configured; everything else is the zero-amount proof middleware.
            var middleware = proofMiddleware
            #if MPP_TEMPO_FFI_ENABLED
                if (request.path ?? "").hasPrefix("/session"), let sessionMiddleware {
                    middleware = sessionMiddleware
                }
            #endif
            let (response, responseBody) = await middleware.handle(
                request, body: body, now: Date(), handler: serve
            )
            log("[server] -> \(response.status.code) "
                + (String(data: responseBody, encoding: .utf8) ?? ""))
            writeResponse(response, responseBody, to: connection)
        }
    }
}

// SOCK_STREAM is an enum on Glibc (needs .rawValue) but a plain Int32 on Darwin
// and Musl; normalize to Int32.
#if canImport(Glibc)
    private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
    private let sockStreamType = SOCK_STREAM
#endif
