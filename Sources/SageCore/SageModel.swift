import Foundation

@MainActor
@Observable
public final class SageModel {

    public var messages: [ChatMessage] = []          // UI transcript (bubbles + tool rows)
    public var inputText: String = ""
    public var isStreaming: Bool = false
    public var errorMessage: String?

    // Wire-level conversation the agent loop sends to the backend each turn.
    var transcript: [LLMMessage] = []
    let registry = ToolRegistry()
    public let approvalBroker = ApprovalBroker()
    var loopTask: Task<Void, Never>?

    public var selectedBackend: BackendType = .apple {
        didSet {
            guard selectedBackend != oldValue else { return }
            resetConversation()
        }
    }

    public var systemPrompt: String {
        didSet {
            UserDefaults.standard.set(systemPrompt, forKey: "sage.systemPrompt")
        }
    }

    public var workingDirectory: URL? {
        didSet {
            UserDefaults.standard.set(workingDirectory?.path, forKey: "sage.workingDirectory")
            seedTranscript()
        }
    }

    public let apple = AppleBackend()
    public let llama = LlamaCppBackend()

    public var currentBackend: any ModelBackend {
        switch selectedBackend {
        case .apple:    return apple
        case .llamaCpp: return llama
        }
    }

    public var isAvailable: Bool { currentBackend.isAvailable }
    public var unavailabilityReason: String? { currentBackend.unavailabilityReason }
    public var isMuted: Bool { false }

    // The prompt actually sent to backends — user prompt + cwd context + tool guidance.
    public var effectiveSystemPrompt: String {
        var parts = [systemPrompt]
        if let cwd = workingDirectory {
            parts.append("""
            Working directory: \(cwd.path)

            You have tools to read, search, edit, and run commands in this project, and to search and fetch the web.

            Ground every answer in what the tools actually show — never guess or invent project details:
            - Before describing, documenting, or editing the project, FIRST inspect it: use list_dir to see the layout and read_file/grep to read the relevant files. Do not write about files you have not read.
            - Only after exploring should you write or edit. When creating docs like a README, base every statement on files you actually read this session.
            - Prefer str_replace for small edits over rewriting whole files.
            - Cite web sources you rely on.
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    public init() {
        systemPrompt = UserDefaults.standard.string(forKey: "sage.systemPrompt")
            ?? "You are Sage, a helpful assistant. Be concise and accurate."
        if let path = UserDefaults.standard.string(forKey: "sage.workingDirectory"),
           FileManager.default.fileExists(atPath: path) {
            workingDirectory = URL(fileURLWithPath: path)
        }
        registerTools()
        seedTranscript()
    }

    private func registerTools() {
        registry.register(ReadFileTool())
        registry.register(ListDirTool())
        registry.register(GrepTool())
        registry.register(WriteFileTool())
        registry.register(StrReplaceTool())
        registry.register(RunShellTool())
        registry.register(FetchURLTool())
        registry.register(WebSearchTool())
    }

    public func start() {
        seedTranscript()
    }

    /// Reset the wire transcript to just the (current) system message.
    func seedTranscript() {
        let system = effectiveSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = system.isEmpty ? [] : [.system(system)]
    }

    private func resetConversation() {
        loopTask?.cancel()
        loopTask = nil
        isStreaming = false
        messages.removeAll()
        errorMessage = nil
        seedTranscript()
    }

    public func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, content: text))
        transcript.append(.user(text))
        isStreaming = true

        let task = Task { await runAgentLoop() }
        loopTask = task
        await task.value
    }

    /// Cancel an in-flight agent loop.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        isStreaming = false
        if approvalBroker.pending != nil { approvalBroker.resolvePending(false) }
    }

    public func newConversation() {
        resetConversation()
    }

    public func applySystemPrompt() {
        seedTranscript()
    }
}
