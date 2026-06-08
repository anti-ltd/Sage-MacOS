import Foundation
import AppKit

// Drives a local llama-server subprocess (from `brew install llama.cpp`) and speaks
// OpenAI-compatible streaming chat completions over localhost HTTP via the shared
// OpenAICompatibleClient. The agent loop owns conversation history; this class owns
// only the server lifecycle and the transport config.

@MainActor
@Observable
public final class LlamaCppBackend: ModelBackend {
    public let type: BackendType = .llamaCpp
    public var supportsTools: Bool { true }

    public var modelURL: URL? {
        didSet {
            guard let url = modelURL else { return }
            UserDefaults.standard.set(url.path, forKey: "sage.llamaModelPath")
        }
    }

    public var serverStatus: ServerStatus = .idle
    public var loadingProgress: String = ""

    // Homebrew install of llama.cpp, driven from Settings when the binary is missing.
    public enum InstallState: Equatable { case idle, installing, failed(String) }
    public var installState: InstallState = .idle
    public var installProgress: String = ""

    private var serverProcess: Process?
    private let port = 28_450

    public enum ServerStatus: Equatable {
        case idle         // no model loaded yet
        case starting     // llama-server launching / model loading
        case ready        // healthy, accepting requests
        case error(String)
    }

    public var modelName: String? { modelURL?.lastPathComponent }

    public var isAvailable: Bool {
        if case .ready = serverStatus { return true }
        return false
    }

    public var unavailabilityReason: String? {
        switch serverStatus {
        case .idle:          return modelURL == nil
                                 ? "Pick a GGUF model in Settings → llama.cpp."
                                 : "Tap Load to start llama-server."
        case .starting:      return loadingProgress.isEmpty ? "Loading model…" : loadingProgress
        case .ready:         return nil
        case .error(let m):  return m
        }
    }

    // Computed status colour for the indicator dot in settings.
    public var statusColor: StatusColor {
        switch serverStatus {
        case .idle:     return .gray
        case .starting: return .yellow
        case .ready:    return .green
        case .error:    return .red
        }
    }
    public enum StatusColor { case gray, yellow, green, red }

    public init() {
        if let path = UserDefaults.standard.string(forKey: "sage.llamaModelPath"),
           FileManager.default.fileExists(atPath: path) {
            modelURL = URL(fileURLWithPath: path)
        }
    }

    // MARK: - ModelBackend

    public func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let client = OpenAICompatibleClient(config: .init(
            baseURL: URL(string: "http://localhost:\(port)/v1")!,
            model: "local"
        ))
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in client.stream(messages: messages, tools: tools) {
                        switch event {
                        case .textDelta(let s):   continuation.yield(.textDelta(s))
                        case .toolCalls(let c):   continuation.yield(.toolCalls(c))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Server lifecycle

    public func loadModelFromPanel() async throws {
        let panel = NSOpenPanel()
        panel.title = "Pick a GGUF model file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // No UTType filter — GGUF isn't a registered type; let user navigate freely
        guard await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) == .OK,
              let url = panel.url else { return }
        modelURL = url
        try await startServer()
    }

    public func startServer() async throws {
        guard let url = modelURL else { return }
        stopServer()

        serverStatus = .starting
        loadingProgress = "Finding llama-server…"

        let binary = Self.llamaServerBinary()
        guard let binary else {
            serverStatus = .error("llama-server not found.\n`brew install llama.cpp`")
            return
        }

        loadingProgress = "Loading \(url.lastPathComponent)…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--model", url.path,
            "--port", "\(port)",
            "--ctx-size", "16384",   // headroom for tool transcripts
            "--jinja",               // enable chat-template tool-call support
            "-ngl", "99",            // full Metal GPU offload
            "--log-disable",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        try process.run()
        serverProcess = process

        // Poll health endpoint — model load can take a while for large GGUFs
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await isHealthy() { serverStatus = .ready; return }
            try await Task.sleep(nanoseconds: 750_000_000)
        }

        serverStatus = .error("Timed out waiting for llama-server to start.")
    }

    public func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        serverStatus = .idle
    }

    // MARK: - Installation

    /// Whether the llama-server binary is present on this machine.
    public var isLlamaServerInstalled: Bool { Self.llamaServerBinary() != nil }

    /// Whether Homebrew is available to install it with.
    public var isHomebrewInstalled: Bool { Self.brewBinary() != nil }

    /// Run `brew install llama.cpp`, streaming progress into `installProgress`.
    public func installLlamaCpp() async {
        guard let brew = Self.brewBinary() else {
            installState = .failed("Homebrew not found. Install it from brew.sh, then try again.")
            return
        }
        installState = .installing
        installProgress = "Starting Homebrew…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "llama.cpp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            installState = .failed(error.localizedDescription)
            return
        }

        // brew is chatty; surface the latest line so the install doesn't look frozen.
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { installProgress = trimmed }
            }
        } catch { /* EOF / read end — fall through to exit status */ }

        process.waitUntilExit()

        if process.terminationStatus == 0 && Self.llamaServerBinary() != nil {
            installState = .idle
            installProgress = ""
        } else {
            installState = .failed(installProgress.isEmpty
                ? "Install failed (exit code \(process.terminationStatus))."
                : installProgress)
        }
    }

    private static func brewBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",   // Apple Silicon
            "/usr/local/bin/brew",       // Intel
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Private helpers

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/health") else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(from: url) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private static func llamaServerBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/llama-server",   // Apple Silicon Homebrew
            "/usr/local/bin/llama-server",       // Intel Homebrew
            "/opt/local/bin/llama-server",       // MacPorts
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
