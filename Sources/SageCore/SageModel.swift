import Foundation

@MainActor
@Observable
public final class SageModel {

    public var messages: [ChatMessage] = []
    public var inputText: String = ""
    public var isStreaming: Bool = false
    public var errorMessage: String?

    public var selectedBackend: BackendType = .apple {
        didSet {
            guard selectedBackend != oldValue else { return }
            messages.removeAll()
            errorMessage = nil
            currentBackend.reset(systemPrompt: systemPrompt)
        }
    }

    public var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "sage.systemPrompt") }
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

    public init() {
        systemPrompt = UserDefaults.standard.string(forKey: "sage.systemPrompt")
            ?? "You are Sage, a helpful assistant. Be concise and accurate."
    }

    public func start() {
        apple.reset(systemPrompt: systemPrompt)
        llama.reset(systemPrompt: systemPrompt)
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
            for try await chunk in currentBackend.stream(text) {
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
        currentBackend.reset(systemPrompt: systemPrompt)
    }

    public func applySystemPrompt() {
        apple.reset(systemPrompt: systemPrompt)
        llama.reset(systemPrompt: systemPrompt)
    }
}
