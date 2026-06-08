import Foundation
import FoundationModels

// On-device Apple Intelligence backend. Text-only: FoundationModels has its own
// Tool protocol, but wiring the agent loop into it is a follow-up, so this backend
// reports `supportsTools = false` and the loop runs it as plain chat. Stateless —
// a fresh session is built per turn from the transcript the loop owns.
@MainActor
public final class AppleBackend: ModelBackend {
    public let type: BackendType = .apple
    public var supportsTools: Bool { false }

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public var unavailabilityReason: String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
        switch reason {
        case .deviceNotEligible:           return "This device isn't eligible for on-device AI."
        case .modelNotReady:               return "On-device model isn't ready yet. Try again shortly."
        case .appleIntelligenceNotEnabled: return "Enable Apple Intelligence in System Settings."
        @unknown default:                  return "On-device AI is unavailable."
        }
    }

    public func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        // Split the transcript: system → instructions, the rest → a flattened prompt.
        let instructions = messages.first(where: { $0.role == .system })?.content ?? ""
        let conversation = messages.filter { $0.role == .user || $0.role == .assistant }
        let prompt = Self.flatten(conversation)

        let session = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: instructions)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var previous = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        // FoundationModels yields the cumulative string; emit only the delta.
                        let full = partial.content
                        if full.count > previous.count {
                            let delta = String(full.dropFirst(previous.count))
                            continuation.yield(.textDelta(delta))
                            previous = full
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Render prior turns as a readable transcript ending with the latest user message.
    private static func flatten(_ messages: [LLMMessage]) -> String {
        guard messages.count > 1 else { return messages.last?.content ?? "" }
        return messages.map { m in
            let speaker = m.role == .user ? "User" : "Assistant"
            return "\(speaker): \(m.content ?? "")"
        }.joined(separator: "\n\n")
    }
}
