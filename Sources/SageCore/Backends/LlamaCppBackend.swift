import Foundation
import AppKit

// Drives a local llama-server subprocess (from `brew install llama.cpp`) and
// speaks OpenAI-compatible streaming chat completions over localhost HTTP.
// No C/Swift interop — Metal/GPU is handled by the llama.cpp binary itself.

@MainActor
@Observable
public final class LlamaCppBackend: ModelBackend {
    public let type: BackendType = .llamaCpp

    public var modelURL: URL? {
        didSet {
            guard let url = modelURL else { return }
            UserDefaults.standard.set(url.path, forKey: "sage.llamaModelPath")
        }
    }

    public var serverStatus: ServerStatus = .idle
    public var loadingProgress: String = ""

    private var serverProcess: Process?
    private let port = 28_450
    private var systemPromptStore = ""
    // Conversation history — rebuilt into each request body (OpenAI API is stateless).
    private var history: [(role: String, content: String)] = []

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

    public func reset(systemPrompt: String) {
        systemPromptStore = systemPrompt
        history.removeAll()
    }

    public func stream(_ userText: String) -> AsyncThrowingStream<String, Error> {
        history.append((role: "user", content: userText))
        let messages = buildMessages()
        let port = self.port

        return AsyncThrowingStream { [weak self] continuation in
            Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    var accumulated = ""
                    let url = URL(string: "http://localhost:\(port)/v1/chat/completions")!
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": "local",
                        "messages": messages,
                        "stream": true,
                        "temperature": 0.7,
                        "max_tokens": 4096,
                    ])

                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard
                            let data = payload.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let choices = json["choices"] as? [[String: Any]],
                            let delta = choices.first?["delta"] as? [String: Any],
                            let piece = delta["content"] as? String
                        else { continue }
                        accumulated += piece
                        continuation.yield(accumulated)
                    }
                    self.history.append((role: "assistant", content: accumulated))
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
            "--ctx-size", "8192",
            "-ngl", "99",          // full Metal GPU offload
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
        history.removeAll()
    }

    // MARK: - Private helpers

    private func buildMessages() -> [[String: String]] {
        var out = [[String: String]]()
        if !systemPromptStore.isEmpty {
            out.append(["role": "system", "content": systemPromptStore])
        }
        for m in history { out.append(["role": m.role, "content": m.content]) }
        return out
    }

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
