import Foundation
import FoundationModels

@MainActor
public final class ChatEngine {
    private var session: LanguageModelSession?

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public var unavailabilityReason: String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
        switch reason {
        case .deviceNotEligible:          return "This device isn't eligible for on-device AI."
        case .modelNotReady:              return "The on-device model isn't ready yet. Try again shortly."
        case .appleIntelligenceNotEnabled: return "Enable Apple Intelligence in System Settings to use Sage."
        @unknown default:                 return "On-device AI is unavailable."
        }
    }

    public func reset(systemPrompt: String) {
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        session = prompt.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: prompt)
    }

    /// Returns a stream of accumulated response text chunks.
    public func stream(_ text: String) -> AsyncThrowingStream<String, Error> {
        if session == nil { reset(systemPrompt: "") }
        let current = session!
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let responseStream = current.streamResponse(to: text)
                    for try await partial in responseStream {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
