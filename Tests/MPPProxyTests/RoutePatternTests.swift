import Testing
@testable import MPPProxy

@Suite("RoutePattern matching + rendering")
struct RoutePatternTests {
    @Test("literal segments match exactly and reject a mismatch or length difference")
    func literalMatch() throws {
        let pattern = try RoutePattern("/v1/chat/completions")
        #expect(pattern.match(["v1", "chat", "completions"]) != nil)
        #expect(pattern.match(["v1", "chat"]) == nil)
        #expect(pattern.match(["v1", "chat", "completions", "extra"]) == nil)
        #expect(pattern.match(["v1", "chat", "other"]) == nil)
    }

    @Test("a capture segment matches any single value and records it")
    func captureMatch() throws {
        for spelling in ["/v1/users/{id}", "/v1/users/:id"] {
            let pattern = try RoutePattern(spelling)
            #expect(pattern.match(["v1", "users", "42"]) == ["id": "42"])
            #expect(pattern.match(["v1", "users"]) == nil)
            #expect(pattern.match(["v1", "users", "42", "x"]) == nil)
        }
    }

    @Test("a single-segment wildcard matches one segment without capturing")
    func wildcardMatch() throws {
        let pattern = try RoutePattern("/v1/*/raw")
        #expect(pattern.match(["v1", "anything", "raw"]) == [:])
        #expect(pattern.match(["v1", "raw"]) == nil)
    }

    @Test("a trailing rest-wildcard consumes all remaining segments")
    func restMatch() throws {
        let pattern = try RoutePattern("/files/**")
        #expect(pattern.match(["files", "a", "b", "c"]) == [:])
        #expect(pattern.match(["files"]) == [:])
    }

    @Test("an empty pattern matches only the empty path")
    func emptyMatch() throws {
        let pattern = try RoutePattern("/")
        #expect(pattern.match([]) == [:])
        #expect(pattern.match(["x"]) == nil)
    }

    @Test("a rest-wildcard before the final segment is rejected")
    func restNotFinalThrows() {
        #expect(throws: RoutePattern.ParseError.self) { try RoutePattern("/files/**/raw") }
    }

    @Test("a malformed brace segment is rejected")
    func malformedThrows() {
        #expect(throws: RoutePattern.ParseError.self) { try RoutePattern("/v1/{id") }
    }

    @Test("openAPIPath renders captures as {name} and keeps wildcards literal")
    func openAPIRendering() throws {
        #expect(try RoutePattern("/v1/users/:id").openAPIPath() == "/v1/users/{id}")
        #expect(try RoutePattern("/v1/users/{id}").openAPIPath() == "/v1/users/{id}")
        #expect(try RoutePattern("/files/**").openAPIPath() == "/files/**")
    }
}
