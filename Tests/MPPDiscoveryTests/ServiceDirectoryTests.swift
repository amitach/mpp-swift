import Foundation
import MPPDiscovery
import Testing

@Suite("ServiceDirectory")
struct ServiceDirectoryTests {
    // A realistic mpp.dev/services/llms.txt: a markdown preamble whose Tempo-Wallet example command
    // itself contains a bracketed JSON array, then the real services array inside a ```json fence.
    private let llmsText = """
    # MPP Services
    > Docs: https://mpp.dev/overview

    ## Tempo Wallet
    Make a request (payment handled automatically):
      $ tempo request https://openai.mpp.tempo.xyz/v1/chat/completions \\
        -X POST --json '{"model":"gpt-4o","messages":[{"role":"user","content":"Hi"}]}'

    ## Services

    ```json
    [
      {"id":"anthropic","name":"Anthropic","description":"Claude.","categories":["ai"],
       "serviceUrl":"https://anthropic.mpp.tempo.xyz"},
      {"id":"exa","name":"Exa","description":"Search.","categories":["search","ai"],
       "serviceUrl":"https://exa.mpp.tempo.xyz"}
    ]
    ```
    """

    @Test("parses the fenced JSON block, ignoring bracketed preamble examples")
    func parsesLlmsText() throws {
        let entries = try ServiceDirectory.parse(llmsText)
        #expect(entries.map(\.id) == ["anthropic", "exa"])
        #expect(entries[0].url == URL(string: "https://anthropic.mpp.tempo.xyz"))
        #expect(entries[1].categories == ["search", "ai"])
    }

    @Test("parses a raw JSON array (the /api/services shape)")
    func parsesRawJSON() throws {
        let raw = #"""
        [{"id":"exa","name":"Exa","serviceUrl":"https://exa.mpp.tempo.xyz","description":"x","categories":["search"]}]
        """#
        let entries = try ServiceDirectory.parse(raw)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Exa")
        #expect(entries[0].url == URL(string: "https://exa.mpp.tempo.xyz"))
    }

    @Test("isIn(category:) matches case-insensitively")
    func categoryFilter() throws {
        let entries = try ServiceDirectory.parse(llmsText)
        #expect(entries.filter { $0.isIn(category: "AI") }.map(\.id) == ["anthropic", "exa"])
        #expect(entries.filter { $0.isIn(category: "search") }.map(\.id) == ["exa"])
    }

    @Test("text with no JSON array throws notJSON")
    func notJSON() {
        #expect(throws: ServiceDirectory.ParseError.notJSON) {
            try ServiceDirectory.parse("# MPP Services\n\nNo services here.")
        }
    }
}
