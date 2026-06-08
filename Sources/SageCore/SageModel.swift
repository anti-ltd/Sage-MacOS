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
    var hasReadThisTurn = false   // read-before-write gate: set once the model reads source content
    var projectHasSource = false  // whether the working dir has code/manifest files (gate only applies if so)
    private var projectTreeText = ""   // cached recursive file listing injected into the system prompt

    public var selectedBackend: BackendType = .apple {
        didSet {
            guard selectedBackend != oldValue else { return }
            UserDefaults.standard.set(selectedBackend.rawValue, forKey: "sage.selectedBackend")
            resetConversation()
            autostartLlamaIfNeeded()
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
            - Determine what the project IS only by reading its build manifest (Package.swift, *.xcodeproj, package.json, Cargo.toml, etc.) AND its actual source files. Do NOT infer the project's purpose from its name or from an existing README — both are frequently misleading or out of date. (For example, a name containing "Bar" might mean a menu-bar app, not a drinks bar.) When a README already exists, treat it as unverified: confirm every claim against the code before repeating it.
            - Never invent features, dependencies, version numbers, install commands, or URLs. If a fact is not backed by a file you read this session, omit it or say it is unknown.
            - Do not narrate or announce tool calls ("I'll now read X", "Let me check Y") — just call the tool. Never type out or guess a file's contents from memory; rely only on what read_file returns, and do not paste file contents into the chat unless the user explicitly asks to see them.
            - Keep replies concise: give the result, not a play-by-play of your steps.
            - Only after exploring should you write or edit. When creating docs like a README, base every statement on files you actually read this session.
            - When you decide to create or change a file, you MUST apply it by calling write_file or str_replace. Never paste the new file contents into your reply as a substitute for calling the tool — pasting does not change anything on disk.
            - Prefer str_replace for small edits over rewriting whole files.
            - Cite web sources you rely on.
            """)
            if !projectTreeText.isEmpty {
                parts.append("""
                Project files (the actual layout — read the relevant ones with read_file before describing or editing the project; do not rely on directory names alone):
                \(projectTreeText)
                """)
            }
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
        // didSet doesn't fire during init, so restoring here has no side effects.
        if let raw = UserDefaults.standard.string(forKey: "sage.selectedBackend"),
           let backend = BackendType(rawValue: raw) {
            selectedBackend = backend
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
        autostartLlamaIfNeeded()
    }

    /// Start llama-server unprompted when it's the active backend, a model is set,
    /// and the server is idle — so the user doesn't have to tap Load each time.
    func autostartLlamaIfNeeded() {
        guard selectedBackend == .llamaCpp, llama.modelURL != nil else { return }
        if case .idle = llama.serverStatus {
            Task { try? await llama.startServer() }
        }
    }

    /// Reset the wire transcript to just the (current) system message.
    func seedTranscript() {
        refreshProjectContext()
        let system = effectiveSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = system.isEmpty ? [] : [.system(system)]
    }

    /// Recompute the cached project file tree + whether the project has source files.
    private func refreshProjectContext() {
        guard let wd = workingDirectory else {
            projectTreeText = ""; projectHasSource = false; return
        }
        let result = Self.projectTree(wd)
        projectTreeText = result.text
        projectHasSource = result.hasSource
    }

    /// A bounded, recursive listing of the project's files (relative paths), plus whether any
    /// are code/manifest files. Skips build/VCS dirs. Injected into the system prompt so the
    /// model sees the real layout up front instead of having to recurse with many list_dir calls.
    nonisolated static func projectTree(_ root: URL, maxEntries: Int = 250) -> (text: String, hasSource: Bool) {
        let fm = FileManager.default
        let sourceExt: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go",
                                      "rb", "java", "kt", "m", "mm", "c", "cpp", "h"]
        let manifests: Set<String> = ["package.swift", "package.json", "cargo.toml", "go.mod",
                                      "pyproject.toml", "gemfile", "makefile"]
        var files: [String] = []
        var hasSource = false
        var truncated = false

        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in en {
                let p = url.path
                if p.contains("/.git/") || p.contains("/.build/") || p.contains("/build/")
                    || p.contains("/node_modules/") || p.contains("/.swiftpm/") {
                    en.skipDescendants(); continue
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                if sourceExt.contains(url.pathExtension.lowercased())
                    || manifests.contains(url.lastPathComponent.lowercased()) {
                    hasSource = true
                }
                files.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
                if files.count >= maxEntries { truncated = true; break }
            }
        }
        files.sort()
        let text = files.joined(separator: "\n") + (truncated ? "\n… (more files not listed)" : "")
        return (text, hasSource)
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
