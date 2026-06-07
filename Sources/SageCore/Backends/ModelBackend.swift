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

@MainActor
public protocol ModelBackend: AnyObject {
    var type: BackendType { get }
    var isAvailable: Bool { get }
    var unavailabilityReason: String? { get }
    func reset(systemPrompt: String)
    func stream(_ userText: String) -> AsyncThrowingStream<String, Error>
}
