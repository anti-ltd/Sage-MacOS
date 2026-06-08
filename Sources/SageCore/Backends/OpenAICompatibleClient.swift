import Foundation

// Provider-agnostic transport for any OpenAI-compatible `/chat/completions`
// endpoint. llama.cpp's local server uses it with no key; remote providers
// (OpenAI, OpenRouter, Together, …) drop in by changing baseURL + apiKey + model.
// This is the single seam for "openai links later" — backends own lifecycle/UX,
// this owns the wire format.
public struct OpenAICompatibleClient: Sendable {

    public struct Config: Sendable {
        public var baseURL: URL          // e.g. http://localhost:28450/v1
        public var apiKey: String?
        public var model: String
        public var extraHeaders: [String: String]

        public init(
            baseURL: URL,
            apiKey: String? = nil,
            model: String = "local",
            extraHeaders: [String: String] = [:]
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.extraHeaders = extraHeaders
        }
    }

    public enum StreamEvent: Sendable {
        case textDelta(String)
        case toolCalls([ToolCall])   // emitted once, after the turn finishes with tool calls
    }

    public let config: Config

    public init(config: Config) {
        self.config = config
    }

    public func stream(
        messages: [LLMMessage],
        tools: [ToolSpec],
        temperature: Double = 0.7,
        maxTokens: Int = 4096
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let config = self.config
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var body: [String: Any] = [
                        "model": config.model,
                        "messages": Self.encodeMessages(messages),
                        "stream": true,
                        "temperature": temperature,
                        "max_tokens": maxTokens,
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools.map { $0.openAIJSON() }
                        body["tool_choice"] = "auto"
                    }

                    var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = config.apiKey {
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    for (k, v) in config.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw ToolError.message("Model server returned HTTP \(http.statusCode).")
                    }

                    var toolAccumulator = ToolCallAccumulator()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first
                        else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let piece = delta["content"] as? String, !piece.isEmpty {
                                continuation.yield(.textDelta(piece))
                            }
                            if let calls = delta["tool_calls"] as? [[String: Any]] {
                                toolAccumulator.ingest(calls)
                            }
                        }
                    }

                    let finished = toolAccumulator.finish()
                    if !finished.isEmpty {
                        continuation.yield(.toolCalls(finished))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Message encoding

    static func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        messages.map { m in
            var dict: [String: Any] = ["role": m.role.rawValue]
            // tool/assistant messages may legitimately have nil content; send "" so
            // strict servers don't reject the turn.
            dict["content"] = m.content ?? ""
            if let calls = m.toolCalls, !calls.isEmpty {
                dict["tool_calls"] = calls.map { c in
                    [
                        "id": c.id,
                        "type": "function",
                        "function": ["name": c.name, "arguments": c.arguments],
                    ] as [String: Any]
                }
            }
            if let id = m.toolCallId {
                dict["tool_call_id"] = id
            }
            return dict
        }
    }
}

// Reassembles streamed tool-call fragments. The OpenAI streaming format splits a
// single call across many deltas keyed by `index`: id/name arrive first, then the
// `arguments` JSON streams in piece by piece.
struct ToolCallAccumulator {
    private struct Partial { var id = ""; var name = ""; var arguments = "" }
    private var byIndex: [Int: Partial] = [:]
    private var order: [Int] = []

    mutating func ingest(_ deltas: [[String: Any]]) {
        for d in deltas {
            let index = d["index"] as? Int ?? 0
            if byIndex[index] == nil {
                byIndex[index] = Partial()
                order.append(index)
            }
            if let id = d["id"] as? String, !id.isEmpty { byIndex[index]?.id = id }
            if let fn = d["function"] as? [String: Any] {
                if let name = fn["name"] as? String, !name.isEmpty { byIndex[index]?.name = name }
                if let args = fn["arguments"] as? String { byIndex[index]?.arguments += args }
            }
        }
    }

    func finish() -> [ToolCall] {
        order.compactMap { idx in
            guard let p = byIndex[idx], !p.name.isEmpty else { return nil }
            let id = p.id.isEmpty ? "call_\(idx)" : p.id
            return ToolCall(id: id, name: p.name, arguments: p.arguments)
        }
    }
}
