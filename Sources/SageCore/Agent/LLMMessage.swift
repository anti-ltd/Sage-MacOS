import Foundation

// Wire-level message model in OpenAI chat shape. This is the agent loop's source
// of truth for conversation history — distinct from `ChatMessage`, which is the
// UI model. Backends translate `[LLMMessage]` into their own request format.
public struct LLMMessage: Sendable {
    public enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCall]?   // assistant turns that requested tools
    public var toolCallId: String?      // tool-result turns: which call they answer

    public init(
        role: Role,
        content: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: text)
    }
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: text)
    }
    public static func toolResult(_ text: String, callId: String) -> LLMMessage {
        LLMMessage(role: .tool, content: text, toolCallId: callId)
    }
}
