import Foundation

public enum BackendType: String, CaseIterable, Identifiable, Sendable {
    case apple    = "Apple Intelligence"
    case llamaCpp = "llama.cpp"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .apple:    return "apple.logo"
        case .llamaCpp: return "cpu"
        }
    }

    public var shortLabel: String {
        switch self {
        case .apple:    return "Apple"
        case .llamaCpp: return "llama.cpp"
        }
    }
}

/// What a single backend turn emits as it streams.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCalls([ToolCall])   // the turn finished by requesting these tool calls
}

/// A model turn-executor. Backends are now *stateless* about conversation history —
/// the agent loop owns the transcript and passes the full message list each turn.
@MainActor
public protocol ModelBackend: AnyObject {
    var type: BackendType { get }
    var isAvailable: Bool { get }
    var unavailabilityReason: String? { get }
    /// Whether this backend can take a `tools` list and emit `.toolCalls`.
    var supportsTools: Bool { get }
    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error>
}
