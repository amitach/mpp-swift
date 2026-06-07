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

    @Test("a ```jsonl block before the real ```json fence is not mistaken for it")
    func ignoresLongerFenceTag() throws {
        let text = """
        ## Examples
        ```jsonl
        {"not":"the services array"}
        ```
        ## Services
        ```json
        [{"id":"exa","name":"Exa","description":"Search.","categories":["search"],
          "serviceUrl":"https://exa.mpp.tempo.xyz"}]
        ```
        """
        #expect(try ServiceDirectory.parse(text).map(\.id) == ["exa"])
    }

    @Test("text with no JSON array throws notJSON")
    func notJSON() {
        #expect(throws: ServiceDirectory.ParseError.notJSON) {
            try ServiceDirectory.parse("# MPP Services\n\nNo services here.")
        }
    }

    @Test("the public initializer builds an entry directly, matching the decoded shape")
    func memberwiseInit() throws {
        let built = ServiceDirectoryEntry(
            id: "exa",
            name: "Exa",
            serviceURL: "https://exa.mpp.tempo.xyz",
            description: "Search.",
            categories: ["search", "ai"]
        )
        let decoded = try ServiceDirectory.parse(llmsText).first { $0.id == "exa" }
        #expect(built == decoded)
        #expect(built.url == URL(string: "https://exa.mpp.tempo.xyz"))
        #expect(built.isIn(category: "AI"))
    }

    @Test("a literal ``` inside a JSON string value does not close the fence early")
    func backticksInsideStringDoNotCloseFence() throws {
        // The description carries a mid-line ``` -- a content-unaware scanner would cut the block
        // here and fail to decode; the line-anchored closing fence reads the whole array.
        let text = """
        ## Services
        ```json
        [{"id":"exa","name":"Exa","description":"Fence ``` inside.","categories":["search"],
          "serviceUrl":"https://exa.mpp.tempo.xyz"}]
        ```
        """
        let entries = try ServiceDirectory.parse(text)
        #expect(entries.map(\.id) == ["exa"])
        #expect(entries[0].description == "Fence ``` inside.")
    }

    @Test("a mid-line ```json in prose is not treated as an opening fence")
    func midLineFenceIsNotAnOpener() throws {
        // The preamble mentions ```json inline; only the real column-0 fence opens the block.
        let text = """
        Wrap the array in a ```json block, like this:
        ```json
        [{"id":"exa","name":"Exa","description":"Search.","categories":["search"],
          "serviceUrl":"https://exa.mpp.tempo.xyz"}]
        ```
        """
        #expect(try ServiceDirectory.parse(text).map(\.id) == ["exa"])
    }

    @Test("a directory with CRLF line endings parses")
    func parsesCRLF() throws {
        let text = [
            "## Services", "```json",
            #"[{"id":"exa","name":"Exa","description":"Search.","categories":["search"],"#,
            #"  "serviceUrl":"https://exa.mpp.tempo.xyz"}]"#, "```",
        ].joined(separator: "\r\n")
        let entries = try ServiceDirectory.parse(text)
        #expect(entries.map(\.id) == ["exa"])
        #expect(entries[0].url == URL(string: "https://exa.mpp.tempo.xyz"))
    }
}
