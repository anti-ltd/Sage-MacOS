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

        hasReadThisTurn = false            // read-before-write gate resets each user turn
        var writtenPaths: [String] = []    // files changed this turn, for the verification pass
        var verificationDone = false

        // If the user asked to create/edit a file, the turn must end with an actual write —
        // not the model pasting file contents into its reply.
        let userRequest = transcript.last(where: { $0.role == .user })?.content ?? ""
        let expectsWrite = Self.looksLikeWriteRequest(userRequest)
        var writeNudgeDone = false

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
                // INDEPENDENT verification pass (fresh context, fed the real source) and
                // feed any findings back so the model can correct them.
                if !verificationDone, !writtenPaths.isEmpty {
                    verificationDone = true
                    if await verifyAndMaybeCorrect(writtenPaths) { continue }
                } else if expectsWrite, writtenPaths.isEmpty, !writeNudgeDone {
                    // The user wanted a file written, but the model answered in prose and
                    // saved nothing. Drop that answer and make it actually use the tool —
                    // which then trips the read-before-write gate and forces grounding.
                    writeNudgeDone = true
                    messages.removeAll { $0.id == bubbleID }
                    injectWriteNudge()
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

        isStreaming = false
        loopTask = nil
    }

    /// Whether a path points at code or a build manifest (vs. a doc like README). Used by the
    /// read-before-write gate so reading only the README doesn't count as grounding.
    nonisolated static func isSourceLikePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        let sourceExt: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go",
                                      "rb", "java", "kt", "m", "mm", "c", "cpp", "h"]
        let manifests: Set<String> = ["package.swift", "package.json", "cargo.toml", "go.mod",
                                      "pyproject.toml", "gemfile", "makefile"]
        return sourceExt.contains(ext) || manifests.contains(name)
    }

    /// Heuristic: did the user ask to create or modify a file (vs. just ask a question)?
    nonisolated static func looksLikeWriteRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        // Read-only / question intent (e.g. "verify the readme it created") suppresses the nudge.
        let readOnly = ["verify", "check", "review", "show", "read ", "what", "explain",
                        "describe", "list", "summar", "how ", "why ", "does ", "is "]
        if readOnly.contains(where: t.contains) { return false }

        let verbs = ["create", "write", "update", "edit", "add ", "generate", "make ",
                     "fix", "modify", "rewrite", "append", "implement"]
        let nouns = ["readme", "file", ".md", ".swift", ".txt", ".json", "license",
                     "document", "changelog", "docs"]
        return verbs.contains(where: t.contains) && nouns.contains(where: t.contains)
    }

    /// Reject a prose answer that should have been a file write, and steer the model to the tool.
    private func injectWriteNudge() {
        transcript.append(.user("""
        You saved nothing to disk this turn and printed file contents in your reply instead. The \
        request was to create or modify a file. Do not paste file contents as an answer. First \
        read the relevant source (the build manifest and the main files) to ground it, then create \
        or edit the file with write_file or str_replace. If no file change is actually needed, say \
        so in one sentence.
        """))
    }

    // MARK: - Independent verification

    /// Check the written file(s) against the real source in a *fresh* context (the verifier
    /// never sees the conversation that produced them, so it can't defend its own story).
    /// Returns true if it injected corrections and the main loop should continue.
    private func verifyAndMaybeCorrect(_ paths: [String]) async -> Bool {
        guard let wd = workingDirectory else { return false }
        let list = Array(Set(paths)).sorted()

        let row = ChatMessage(role: .assistant, toolActivity: ToolActivity(
            name: "verify",
            detail: "Independently checking \(list.joined(separator: ", ")) against the source",
            status: .running))
        let rowID = row.id
        messages.append(row)

        let source = Self.gatherGroundTruth(wd)
        let docs = list.compactMap { p -> String? in
            guard let url = try? ToolContext(workingDirectory: wd, requestApproval: { _, _ in false }).resolve(p),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "=== DOCUMENT: \(p) ===\n\(text)"
        }.joined(separator: "\n\n")

        let verifierTranscript: [LLMMessage] = [
            .system("""
            You are a strict fact-checker. You are given a project's ACTUAL source code, then \
            one or more documents written about it. Check every factual claim in each document \
            against the source. List each claim NOT supported by the source — wrong purpose, \
            invented features, dependencies, version numbers, build/run commands, file names, or \
            license — quoting the claim and stating what the source actually shows. Reason only \
            from the text provided; do not use tools. If every claim is supported, reply with \
            exactly: VERIFIED
            """),
            .user("=== SOURCE (ground truth) ===\n\(source)\n\n\(docs)"),
        ]

        let verdict = await singleCompletion(verifierTranscript)
        let verified = verdict.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().hasPrefix("VERIFIED")

        updateRow(rowID) {
            $0.status = verified ? .ok : .failed
            $0.resultPreview = verified ? "All claims supported by the source" : "Found unsupported claims"
        }

        if verified { return false }

        // Surface what was caught, then ask the model to fix it.
        messages.append(ChatMessage(role: .assistant,
            content: "🔎 Verification found unsupported claims:\n\n\(verdict)"))
        transcript.append(.user("""
        An independent review of the actual source found these unsupported claims in \
        \(list.joined(separator: ", ")). Correct each one with str_replace, grounded strictly in \
        the code. Do not invent anything.

        \(verdict)
        """))
        return true
    }

    /// One tool-free completion; returns the full text (used by the verifier).
    private func singleCompletion(_ messages: [LLMMessage]) async -> String {
        var text = ""
        do {
            for try await event in currentBackend.stream(messages: messages, tools: []) {
                if case .textDelta(let piece) = event { text += piece }
            }
        } catch {
            return "Verification could not run: \(error.localizedDescription)"
        }
        return text
    }

    /// Read the manifest + a bounded sample of source files straight off disk, so the verifier
    /// is guaranteed to see the real code rather than whatever the model chose to read.
    nonisolated static func gatherGroundTruth(_ wd: URL) -> String {
        let fm = FileManager.default
        var blocks: [String] = []
        var budget = 24_000

        func add(_ url: URL, label: String) {
            guard budget > 0,
                  let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) else { return }
            let chunk = String(s.prefix(min(budget, 4_000)))
            budget -= chunk.count
            blocks.append("// \(label)\n\(chunk)")
        }

        for manifest in ["Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Gemfile"] {
            let u = wd.appendingPathComponent(manifest)
            if fm.fileExists(atPath: u.path) { add(u, label: manifest) }
        }

        let codeExt: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "rb", "java", "kt", "m", "mm", "c", "cpp", "h"]
        if let en = fm.enumerator(at: wd, includingPropertiesForKeys: nil) {
            var count = 0
            for case let url as URL in en {
                let p = url.path
                if p.contains("/.git/") || p.contains("/.build/") || p.contains("/build/") || p.contains("/node_modules/") {
                    en.skipDescendants(); continue
                }
                guard codeExt.contains(url.pathExtension.lowercased()) else { continue }
                add(url, label: url.path.replacingOccurrences(of: wd.path + "/", with: ""))
                count += 1
                if count >= 12 || budget <= 0 { break }
            }
        }
        return blocks.isEmpty ? "(no source files found)" : blocks.joined(separator: "\n\n")
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

        // Read-before-write gate: refuse to edit a project the model hasn't actually read.
        // It must read real file content (read_file/grep) before write_file/str_replace.
        let isWrite = call.name == "write_file" || call.name == "str_replace"
        if isWrite && !hasReadThisTurn && projectHasSource {
            updateRow(rowID) { $0.status = .failed; $0.resultPreview = "Blocked: read the source first" }
            transcript.append(.toolResult("""
            Blocked: you have not read any source files yet this turn, so you cannot write grounded \
            content. The project's file layout is listed in your instructions — use read_file on the \
            build manifest (e.g. Package.swift) and the main source files to learn what the project \
            actually is and does, then write. Reading only a README does not count; read the code. Do \
            not write from the project's name or directory names.
            """, callId: call.id))
            return nil
        }

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
            // Reading real source content opens the write gate. grep scans file contents, so it
            // counts; read_file counts only for source/manifest files (not just the README).
            if call.name == "grep" {
                hasReadThisTurn = true
            } else if call.name == "read_file",
                      let path = args["path"] as? String,
                      Self.isSourceLikePath(path) {
                hasReadThisTurn = true
            }
            if isWrite {
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
