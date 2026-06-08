import Foundation
import Testing

@testable import SageCore

@Suite("Streamed tool-call reassembly")
struct ToolCallAccumulatorTests {

    // The OpenAI stream splits one call across many deltas: id/name first, then
    // arguments JSON piece by piece. Reassembly must concatenate by index.
    @Test
    func reassemblesFragmentedArguments() {
        var acc = ToolCallAccumulator()
        acc.ingest([["index": 0, "id": "call_1", "function": ["name": "read_file"]]])
        acc.ingest([["index": 0, "function": ["arguments": "{\"pa"]]])
        acc.ingest([["index": 0, "function": ["arguments": "th\":\"a.txt\"}"]]])

        let calls = acc.finish()
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_1")
        #expect(calls[0].name == "read_file")
        #expect(calls[0].argumentValues()["path"] as? String == "a.txt")
    }

    @Test
    func handlesParallelCallsByIndex() {
        var acc = ToolCallAccumulator()
        acc.ingest([
            ["index": 0, "id": "a", "function": ["name": "list_dir", "arguments": "{}"]],
            ["index": 1, "id": "b", "function": ["name": "grep", "arguments": "{\"pattern\":\"x\"}"]],
        ])
        let calls = acc.finish()
        #expect(calls.count == 2)
        #expect(calls[0].name == "list_dir")
        #expect(calls[1].name == "grep")
    }

    @Test
    func dropsCallsWithoutAName() {
        var acc = ToolCallAccumulator()
        acc.ingest([["index": 0, "function": ["arguments": "{}"]]])
        #expect(acc.finish().isEmpty)
    }
}

@Suite("Inline tool-call recovery")
struct InlineToolCallTests {

    // The exact failure from the screenshot: write_file emitted as a fenced JSON
    // block, with nested braces inside the arguments object.
    @Test
    func recoversFencedWriteFileWithNestedBraces() {
        let text = """
        ```json
        {
          "name": "write_file",
          "arguments": { "path": "README.md", "content": "# Title\\n\\nbody {with} braces" }
        }
        ```
        """
        let objects = SageModel.balancedJSONObjects(in: text)
        #expect(objects.count == 1)   // not truncated at the first inner }
        let call = SageModel.toolCall(fromJSON: objects[0])
        #expect(call?.name == "write_file")
        #expect(call?.argumentValues()["path"] as? String == "README.md")
        #expect((call?.argumentValues()["content"] as? String)?.contains("{with}") == true)
    }

    @Test
    func recoversTaggedAndBareForms() {
        let tagged = "<tool_call>{\"name\": \"list_dir\", \"arguments\": {}}</tool_call>"
        #expect(SageModel.toolCall(fromJSON: SageModel.balancedJSONObjects(in: tagged)[0])?.name == "list_dir")

        let bare = "{\"name\": \"grep\", \"parameters\": {\"pattern\": \"x\"}}"
        let call = SageModel.toolCall(fromJSON: bare)
        #expect(call?.name == "grep")
        #expect(call?.argumentValues()["pattern"] as? String == "x")
    }

    @Test
    func stripsToolCallJSONFromVisibleText() {
        let known: (String) -> Bool = { ["write_file", "list_dir"].contains($0) }

        // Pure tool-call narration → nothing left to show.
        let only = "```json\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"a\", \"content\": \"x {y}\"}}\n```"
        #expect(SageModel.strippingToolCallJSON(from: only, isToolName: known).isEmpty)

        // Real prose around a call → prose survives, JSON removed.
        let mixed = "Sure, creating it now. {\"name\": \"list_dir\", \"arguments\": {}}"
        let stripped = SageModel.strippingToolCallJSON(from: mixed, isToolName: known)
        #expect(stripped == "Sure, creating it now.")
        #expect(!stripped.contains("list_dir"))
    }

    @Test
    func ignoresProseAndNonToolJSON() {
        #expect(SageModel.balancedJSONObjects(in: "Just a sentence, no JSON.").isEmpty)
        // JSON without a name+arguments shape is not a tool call.
        #expect(SageModel.toolCall(fromJSON: "{\"foo\": 1}") == nil)
    }
}

@Suite("Transcript encoding")
struct MessageEncodingTests {

    @Test
    func encodesAssistantToolCallAndResult() {
        let messages: [LLMMessage] = [
            .system("sys"),
            .user("hi"),
            LLMMessage(role: .assistant, content: nil,
                       toolCalls: [ToolCall(id: "c1", name: "read_file", arguments: "{\"path\":\"a\"}")]),
            .toolResult("file body", callId: "c1"),
        ]
        let json = OpenAICompatibleClient.encodeMessages(messages)
        #expect(json.count == 4)

        let assistant = json[2]
        let calls = assistant["tool_calls"] as? [[String: Any]]
        #expect(calls?.first?["id"] as? String == "c1")
        #expect((calls?.first?["function"] as? [String: Any])?["name"] as? String == "read_file")

        let tool = json[3]
        #expect(tool["role"] as? String == "tool")
        #expect(tool["tool_call_id"] as? String == "c1")
        #expect(tool["content"] as? String == "file body")
    }
}

@Suite("Path confinement")
struct ToolContextTests {

    private func ctx(_ wd: String) -> ToolContext {
        ToolContext(workingDirectory: URL(fileURLWithPath: wd)) { _, _ in true }
    }

    @Test
    func resolvesRelativeInsideProject() throws {
        let url = try ctx("/tmp/proj").resolve("src/a.txt")
        #expect(url.path == "/tmp/proj/src/a.txt")
    }

    @Test
    func rejectsEscapeViaDotDot() {
        #expect(throws: ToolError.self) {
            _ = try ctx("/tmp/proj").resolve("../secret")
        }
    }

    @Test
    func rejectsAbsoluteOutsideProject() {
        #expect(throws: ToolError.self) {
            _ = try ctx("/tmp/proj").resolve("/etc/passwd")
        }
    }
}

@Suite("Web helpers")
struct WebHelperTests {

    @Test
    func stripsHTMLToText() {
        let html = "<html><head><style>x{}</style></head><body><p>Hello &amp; bye</p><script>z()</script></body></html>"
        let text = HTMLText.strip(html)
        #expect(text.contains("Hello & bye"))
        #expect(!text.contains("z()"))
        #expect(!text.contains("<"))
    }

    @Test
    func unwrapsDuckDuckGoRedirect() {
        let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&rut=abc"
        #expect(DuckDuckGoSearch.cleanURL(href) == "https://example.com/page")
    }
}
