import Foundation

public enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

/// A tool step surfaced in the transcript (distinct from the model's prose).
public struct ToolActivity: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case running, ok, failed, denied }
    public var name: String
    public var detail: String       // path, command, or query
    public var status: Status
    public var resultPreview: String?

    public init(name: String, detail: String, status: Status = .running, resultPreview: String? = nil) {
        self.name = name
        self.detail = detail
        self.status = status
        self.resultPreview = resultPreview
    }
}

public struct ChatMessage: Identifiable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var content: String
    public let timestamp: Date
    public var isStreaming: Bool
    /// When set, this row renders as a tool step rather than a chat bubble.
    public var toolActivity: ToolActivity?

    public init(
        role: ChatRole,
        content: String = "",
        isStreaming: Bool = false,
        toolActivity: ToolActivity? = nil
    ) {
        id = UUID()
        self.role = role
        self.content = content
        timestamp = Date()
        self.isStreaming = isStreaming
        self.toolActivity = toolActivity
    }
}
