import Foundation

// MARK: - Approval bridge

/// One pending side-effecting tool call awaiting the user's Approve/Deny.
@MainActor
public struct PendingApproval: Identifiable {
    public let id = UUID()
    public let toolName: String
    public let preview: String
    let respond: (Bool) -> Void
}

/// Mediates between tools (which run off the main actor and ask for approval) and the
/// SwiftUI approval sheet. A @MainActor class is Sendable, so the tool's @Sendable
/// approval closure can safely capture it.
@MainActor
@Observable
public final class ApprovalBroker {
    public var pending: PendingApproval?

    public init() {}

    /// Suspends until the user responds in the UI.
    public func request(name: String, preview: String) async -> Bool {
        await withCheckedContinuation { continuation in
            pending = PendingApproval(toolName: name, preview: preview) { [weak self] granted in
                self?.pending = nil
                continuation.resume(returning: granted)
            }
        }
    }

    public func resolvePending(_ granted: Bool) {
        pending?.respond(granted)
    }
}

// MARK: - Agent loop

extension SageModel {

    static let maxIterations = 12

    /// Drive one user turn to completion: stream the model, execute any tool calls
    /// (with approval), feed results back, and loop until the model stops calling tools.
    func runAgentLoop() async {
        let tools = currentBackend.supportsTools ? registry.specs() : []
        let context = makeToolContext()

        var iterations = 0
        while iterations < Self.maxIterations {
            iterations += 1
            if Task.isCancelled { break }

            // A fresh assistant bubble for this model turn.
            let bubble = ChatMessage(role: .assistant, content: "", isStreaming: true)
            let bubbleID = bubble.id
            messages.append(bubble)

            var text = ""
            var calls: [ToolCall] = []
            do {
                for try await event in currentBackend.stream(messages: transcript, tools: tools) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let piece):
                        text += piece
                        updateMessage(bubbleID) { $0.content = text }
                    case .toolCalls(let c):
                        calls = c
                    }
                }
            } catch {
                updateMessage(bubbleID) {
                    $0.content = text.isEmpty ? "[Error: \(error.localizedDescription)]" : text
                    $0.isStreaming = false
                }
                errorMessage = error.localizedDescription
                break
            }

            updateMessage(bubbleID) { $0.isStreaming = false }

            // Fallback: many local models emit tool calls as text (a ```json block,
            // a <tool_call> tag, or a bare object) instead of the structured
            // tool_calls field. Recover them so the action still runs.
            if calls.isEmpty, !text.isEmpty {
                let inferred = parseInlineToolCalls(text)
                if !inferred.isEmpty { calls = inferred }
            }

            // Never surface raw tool-call JSON in the chat bubble — strip it whether
            // the call arrived structured or as text. Some models narrate the call as
            // content *and* make the structured call, leaving the JSON in `text`.
            let visibleText = calls.isEmpty ? text : strippingToolCallJSON(from: text)
            updateMessage(bubbleID) { $0.content = visibleText }

            // Record the assistant turn in the transcript the model sees next.
            transcript.append(LLMMessage(
                role: .assistant,
                content: visibleText.isEmpty ? nil : visibleText,
                toolCalls: calls.isEmpty ? nil : calls))

            // Drop a bubble that's empty once tool-call JSON is stripped out.
            if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !calls.isEmpty {
                messages.removeAll { $0.id == bubbleID }
            }

            if calls.isEmpty { break }   // model is done

            for call in calls {
                if Task.isCancelled { break }
                await execute(call, context: context)
            }
        }

        isStreaming = false
        loopTask = nil
    }

    /// Resolve, approve if needed, run, and record a single tool call.
    private func execute(_ call: ToolCall, context: ToolContext) async {
        guard let tool = registry.tool(named: call.name) else {
            transcript.append(.toolResult("Unknown tool: \(call.name).", callId: call.id))
            return
        }
        let args = call.argumentValues()
        let detail = tool.approvalPreview(arguments: args)

        // UI row tracking this step.
        let row = ChatMessage(role: .assistant, toolActivity:
            ToolActivity(name: call.name, detail: detail, status: .running))
        let rowID = row.id
        messages.append(row)

        // Approval gate for side-effecting tools.
        if tool.requiresApproval {
            let granted = await context.requestApproval(call, detail)
            if !granted {
                updateRow(rowID) { $0.status = .denied; $0.resultPreview = "Denied" }
                transcript.append(.toolResult("User denied this action.", callId: call.id))
                return
            }
        }

        do {
            let result = try await tool.run(arguments: args, context: context)
            updateRow(rowID) { $0.status = .ok; $0.resultPreview = Self.previewLine(result) }
            transcript.append(.toolResult(result, callId: call.id))
        } catch {
            let message = error.localizedDescription
            updateRow(rowID) { $0.status = .failed; $0.resultPreview = message }
            // Feed the error back so the model can recover rather than crash the loop.
            transcript.append(.toolResult("Error: \(message)", callId: call.id))
        }
    }

    // MARK: - Helpers

    func makeToolContext() -> ToolContext {
        let broker = approvalBroker
        return ToolContext(workingDirectory: workingDirectory) { call, preview in
            await broker.request(name: call.name, preview: preview)
        }
    }

    private func updateMessage(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[idx])
    }

    private func updateRow(_ id: UUID, _ mutate: (inout ToolActivity) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              var activity = messages[idx].toolActivity else { return }
        mutate(&activity)
        messages[idx].toolActivity = activity
    }

    private static func previewLine(_ result: String) -> String {
        let firstLine = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? result
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }

    // MARK: - Inline tool-call recovery

    /// Extract tool calls a model emitted as text rather than structured tool_calls.
    /// Only objects naming a *registered* tool are kept, to avoid misreading prose
    /// that merely contains JSON.
    func parseInlineToolCalls(_ text: String) -> [ToolCall] {
        Self.balancedJSONObjects(in: text)
            .compactMap { Self.toolCall(fromJSON: $0) }
            .filter { registry.tool(named: $0.name) != nil }
    }

    /// Remove tool-call JSON (and its `\`\`\`json` fences / `<tool_call>` tags) from text
    /// the user will see, so only genuine prose remains.
    func strippingToolCallJSON(from text: String) -> String {
        Self.strippingToolCallJSON(from: text) { registry.tool(named: $0) != nil }
    }

    nonisolated static func strippingToolCallJSON(
        from text: String, isToolName: (String) -> Bool
    ) -> String {
        var result = text
        for obj in balancedJSONObjects(in: text) {
            guard let call = toolCall(fromJSON: obj), isToolName(call.name) else { continue }
            result = result.replacingOccurrences(of: obj, with: "")
        }
        for marker in ["```json", "```", "<tool_call>", "</tool_call>"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return every balanced top-level `{…}` object in the text. Brace-counts while
    /// respecting string literals and escapes, so nested objects (e.g. a write_file
    /// `content` argument) don't truncate the match the way a regex would.
    nonisolated static func balancedJSONObjects(in text: String) -> [String] {
        var results: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, j = i
            while j < chars.count {
                let c = chars[j]
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString.toggle() }
                else if !inString {
                    if c == "{" { depth += 1 }
                    else if c == "}" { depth -= 1; if depth == 0 { break } }
                }
                j += 1
            }
            if depth == 0 && j < chars.count {
                results.append(String(chars[i...j]))
                i = j + 1
            } else {
                break   // unbalanced tail — stop
            }
        }
        return results
    }

    /// Parse `{ "name": …, "arguments": {…} }` (also accepts `parameters`) into a ToolCall.
    nonisolated static func toolCall(fromJSON json: String) -> ToolCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String,
              let rawArgs = obj["arguments"] ?? obj["parameters"]
        else { return nil }

        let argsString: String
        if let s = rawArgs as? String {
            argsString = s   // some models double-encode arguments as a JSON string
        } else if let argsData = try? JSONSerialization.data(withJSONObject: rawArgs),
                  let s = String(data: argsData, encoding: .utf8) {
            argsString = s
        } else {
            argsString = "{}"
        }
        return ToolCall(id: "inline_\(name)_\(abs(json.hashValue))", name: name, arguments: argsString)
    }
}
