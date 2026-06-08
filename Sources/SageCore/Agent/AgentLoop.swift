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

        var writtenPaths: [String] = []   // files changed this turn, for the verification pass
        var verificationDone = false
        var verifyRowID: UUID?

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

            // Strip any raw tool-call JSON from the prose (some models narrate the call
            // as content *and* emit the structured call).
            let visibleText = calls.isEmpty ? text : strippingToolCallJSON(from: text)

            // Record the assistant turn in the transcript the model sees next (its own memory).
            transcript.append(LLMMessage(
                role: .assistant,
                content: visibleText.isEmpty ? nil : visibleText,
                toolCalls: calls.isEmpty ? nil : calls))

            // Only the final turn (no further tool calls) shows prose. Turns that end in
            // tool calls are intermediate "I'll now read X" narration — drop the bubble
            // and keep just the tool rows.
            if calls.isEmpty {
                updateMessage(bubbleID) { $0.content = visibleText }
            } else {
                messages.removeAll { $0.id == bubbleID }
            }

            if calls.isEmpty {
                // The model thinks it's done. If it changed any files this turn, run one
                // verification pass: re-read the source and check every claim against it.
                if !verificationDone, !writtenPaths.isEmpty {
                    verificationDone = true
                    verifyRowID = beginVerification(of: writtenPaths)
                    continue
                }
                break
            }

            for call in calls {
                if Task.isCancelled { break }
                if let path = await execute(call, context: context) {
                    writtenPaths.append(path)
                }
            }
        }

        if let id = verifyRowID { updateRow(id) { $0.status = .ok } }
        isStreaming = false
        loopTask = nil
    }

    /// Inject a verification turn: a UI marker plus a transcript instruction telling the
    /// model to re-read the source and reconcile the file(s) it just wrote against it.
    /// Returns the marker row's id so the caller can mark it done when the loop ends.
    private func beginVerification(of paths: [String]) -> UUID {
        let list = Array(Set(paths)).sorted().joined(separator: ", ")
        let row = ChatMessage(role: .assistant, toolActivity: ToolActivity(
            name: "verify",
            detail: "Re-reading the source to check \(list) for unsupported claims",
            status: .running))
        messages.append(row)

        transcript.append(.user("""
        Before finishing, verify your work. Re-read the project's build manifest and the \
        actual source files, then check every factual claim in the file(s) you just wrote \
        (\(list)) against what the code really does. If a claim is not supported by the code — \
        wrong purpose, invented features, dependencies, version numbers, install commands, or \
        URLs — correct it with str_replace. Do not invent anything. If it is all accurate, \
        briefly state what you verified.
        """))
        return row.id
    }

    /// Resolve, approve if needed, run, and record a single tool call.
    /// Returns the file path on a successful write/edit (for the verification pass), else nil.
    @discardableResult
    private func execute(_ call: ToolCall, context: ToolContext) async -> String? {
        guard let tool = registry.tool(named: call.name) else {
            transcript.append(.toolResult("Unknown tool: \(call.name).", callId: call.id))
            return nil
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
                return nil
            }
        }

        do {
            let result = try await tool.run(arguments: args, context: context)
            updateRow(rowID) { $0.status = .ok; $0.resultPreview = Self.previewLine(result) }
            transcript.append(.toolResult(result, callId: call.id))
            if call.name == "write_file" || call.name == "str_replace" {
                return args["path"] as? String
            }
            return nil
        } catch {
            let message = error.localizedDescription
            updateRow(rowID) { $0.status = .failed; $0.resultPreview = message }
            // Feed the error back so the model can recover rather than crash the loop.
            transcript.append(.toolResult("Error: \(message)", callId: call.id))
            return nil
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
