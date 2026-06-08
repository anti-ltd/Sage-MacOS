import Foundation

// MARK: - Tool call & spec

/// A tool invocation requested by the model.
public struct ToolCall: Sendable, Identifiable {
    public let id: String          // provider-assigned id, echoed back in the tool result
    public let name: String
    public let arguments: String   // raw JSON object string

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Parse `arguments` into a dictionary. Returns `[:]` if empty/invalid so tools
    /// can surface a teaching error rather than crash.
    public func argumentValues() -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

/// The declaration we advertise to the model (becomes one entry in the OpenAI `tools` array).
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: any Sendable]   // JSON Schema object

    public init(name: String, description: String, parameters: [String: any Sendable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Encoded as `{ type: "function", function: { name, description, parameters } }`.
    public func openAIJSON() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}

// MARK: - Tool protocol

public enum ToolError: LocalizedError {
    case missingArgument(String)
    case outsideWorkingDirectory(String)
    case notFound(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let n):       return "Missing required argument: \(n)."
        case .outsideWorkingDirectory(let p): return "Path \(p) is outside the project working directory."
        case .notFound(let p):              return "Not found: \(p)."
        case .message(let m):               return m
        }
    }
}

/// Context handed to every tool at run time.
public struct ToolContext: Sendable {
    public let workingDirectory: URL?
    /// Asks the UI to approve a side-effecting action. Returns `true` if granted.
    public let requestApproval: @Sendable (_ call: ToolCall, _ preview: String) async -> Bool

    public init(
        workingDirectory: URL?,
        requestApproval: @escaping @Sendable (_ call: ToolCall, _ preview: String) async -> Bool
    ) {
        self.workingDirectory = workingDirectory
        self.requestApproval = requestApproval
    }

    /// Resolve a (possibly relative) path against the working directory and reject escapes.
    public func resolve(_ path: String) throws -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path).standardizedFileURL
        } else if let base = workingDirectory {
            url = base.appendingPathComponent(path).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: path).standardizedFileURL
        }
        if let base = workingDirectory?.standardizedFileURL {
            if !url.path.hasPrefix(base.path) {
                throw ToolError.outsideWorkingDirectory(path)
            }
        }
        return url
    }
}

/// A capability the agent can invoke. Conform + register to add a new tool — the
/// `ToolRegistry` is the single drop-in seam.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    /// Side-effecting tools (write, shell) return `true`; read-only tools `false`.
    var requiresApproval: Bool { get }
    /// One-line, human-readable preview shown in the approval sheet (command, diff, …).
    func approvalPreview(arguments: [String: Any]) -> String
    /// Execute. Throw to feed an error string back to the model; never crash the loop.
    func run(arguments: [String: Any], context: ToolContext) async throws -> String
}

public extension Tool {
    var requiresApproval: Bool { false }
    func approvalPreview(arguments: [String: Any]) -> String { spec.name }
}

// MARK: - Registry

/// Holds the active tool set. Register tools once at startup; the agent loop reads
/// `specs()` to advertise them and `tool(named:)` to dispatch calls.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: any Tool] = [:]

    public init() {}

    public func register(_ tool: any Tool) {
        tools[tool.spec.name] = tool
    }

    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    public func specs() -> [ToolSpec] {
        tools.values.map(\.spec).sorted { $0.name < $1.name }
    }

    public var isEmpty: Bool { tools.isEmpty }
}
