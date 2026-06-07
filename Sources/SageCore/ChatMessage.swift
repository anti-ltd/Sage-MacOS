import Foundation

public enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

public struct ChatMessage: Identifiable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var content: String
    public let timestamp: Date
    public var isStreaming: Bool

    public init(role: ChatRole, content: String = "", isStreaming: Bool = false) {
        id = UUID()
        self.role = role
        self.content = content
        timestamp = Date()
        self.isStreaming = isStreaming
    }
}
