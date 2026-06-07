import Foundation

@MainActor
@Observable
public final class SageModel {

    public var messages: [ChatMessage] = []
    public var inputText: String = ""
    public var isStreaming: Bool = false
    public var errorMessage: String?

    public var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "sage.systemPrompt") }
    }

    private let engine = ChatEngine()

    public var isAvailable: Bool { engine.isAvailable }
    public var unavailabilityReason: String? { engine.unavailabilityReason }
    public var isMuted: Bool { false }

    public init() {
        systemPrompt = UserDefaults.standard.string(forKey: "sage.systemPrompt")
            ?? "You are Sage, a helpful assistant running entirely on this device. All processing is private and offline."
    }

    public func start() {
        engine.reset(systemPrompt: systemPrompt)
    }

    public func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, content: text))

        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let msgID = assistantMsg.id
        messages.append(assistantMsg)
        isStreaming = true

        do {
            for try await chunk in engine.stream(text) {
                if let idx = messages.firstIndex(where: { $0.id == msgID }) {
                    messages[idx].content = chunk
                }
            }
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content = "[Error: \(error.localizedDescription)]"
            }
            errorMessage = error.localizedDescription
        }

        if let idx = messages.firstIndex(where: { $0.id == msgID }) {
            messages[idx].isStreaming = false
        }
        isStreaming = false
    }

    public func newConversation() {
        messages.removeAll()
        errorMessage = nil
        engine.reset(systemPrompt: systemPrompt)
    }

    public func applySystemPrompt() {
        engine.reset(systemPrompt: systemPrompt)
    }
}
