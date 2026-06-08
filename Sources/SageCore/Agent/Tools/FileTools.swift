import Foundation

// Read-only and write file tools. Read-only tools run without approval but are
// confined to the working directory via ToolContext.resolve(_:).

private let maxToolOutput = 100_000   // characters; protects the context window

private func clamp(_ s: String) -> String {
    guard s.count > maxToolOutput else { return s }
    return String(s.prefix(maxToolOutput)) + "\n… [truncated, \(s.count) chars total]"
}

// MARK: - read_file

public struct ReadFileTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "read_file",
            description: "Read a UTF-8 text file. Returns its contents. Path is relative to the project working directory.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "File path, relative to the project."]],
                "required": ["path"],
            ]
        )
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        let url = try context.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.notFound(path) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.message("\(path) is not UTF-8 text (\(data.count) bytes).")
        }
        return clamp(text)
    }
}

// MARK: - list_dir

public struct ListDirTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "list_dir",
            description: "List the entries of a directory (one per line, directories marked with a trailing /). Defaults to the project root.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Directory path, relative to the project. Defaults to '.'."]],
                "required": [String](),
            ]
        )
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        let path = (arguments["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let url = try context.resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError.notFound("\(path) (directory)")
        }
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lines = entries.map { entry -> String in
            let dir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return dir == true ? entry.lastPathComponent + "/" : entry.lastPathComponent
        }
        return lines.isEmpty ? "(empty directory)" : clamp(lines.joined(separator: "\n"))
    }
}

// MARK: - grep

public struct GrepTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "grep",
            description: "Search the project for a regular expression using ripgrep-style recursive grep. Returns matching lines with file:line prefixes.",
            parameters: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "Regular expression to search for."],
                    "path": ["type": "string", "description": "Subdirectory to search, relative to the project. Defaults to the whole project."],
                ],
                "required": ["pattern"],
            ]
        )
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw ToolError.missingArgument("pattern")
        }
        let searchPath = (arguments["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let url = try context.resolve(searchPath)
        let result = try await runProcess(
            "/usr/bin/grep",
            ["-rnI", "--exclude-dir=.git", "--exclude-dir=.build", pattern, url.path],
            workingDirectory: context.workingDirectory
        )
        if result.exitCode == 1 && result.output.isEmpty {
            return "No matches for /\(pattern)/."
        }
        return clamp(result.output.isEmpty ? result.error : result.output)
    }
}

// MARK: - write_file

public struct WriteFileTool: Tool {
    public init() {}

    public var requiresApproval: Bool { true }

    public var spec: ToolSpec {
        ToolSpec(
            name: "write_file",
            description: "Create or overwrite a text file with the given content. Creates parent directories as needed. Requires user approval.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, relative to the project."],
                    "content": ["type": "string", "description": "Full file contents to write."],
                ],
                "required": ["path", "content"],
            ]
        )
    }

    public func approvalPreview(arguments: [String: Any]) -> String {
        let path = arguments["path"] as? String ?? "?"
        let content = arguments["content"] as? String ?? ""
        let bytes = content.utf8.count
        return "Write \(path) (\(bytes) bytes)"
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard let content = arguments["content"] as? String else {
            throw ToolError.missingArgument("content")
        }
        let url = try context.resolve(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url)
        return "Wrote \(content.utf8.count) bytes to \(path)."
    }
}

// MARK: - str_replace

public struct StrReplaceTool: Tool {
    public init() {}

    public var requiresApproval: Bool { true }

    public var spec: ToolSpec {
        ToolSpec(
            name: "str_replace",
            description: "Replace an exact substring in a file with new text. The old_string must appear exactly once. Use this for precise edits instead of rewriting the whole file. Requires user approval.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, relative to the project."],
                    "old_string": ["type": "string", "description": "Exact text to find. Must be unique in the file."],
                    "new_string": ["type": "string", "description": "Replacement text."],
                ],
                "required": ["path", "old_string", "new_string"],
            ]
        )
    }

    public func approvalPreview(arguments: [String: Any]) -> String {
        let path = arguments["path"] as? String ?? "?"
        let old = (arguments["old_string"] as? String ?? "").prefix(60)
        let new = (arguments["new_string"] as? String ?? "").prefix(60)
        return "Edit \(path)\n- \(old)\n+ \(new)"
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard let oldString = arguments["old_string"] as? String, !oldString.isEmpty else {
            throw ToolError.missingArgument("old_string")
        }
        guard let newString = arguments["new_string"] as? String else {
            throw ToolError.missingArgument("new_string")
        }
        let url = try context.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.notFound(path) }
        let original = try String(contentsOf: url, encoding: .utf8)

        let occurrences = original.components(separatedBy: oldString).count - 1
        if occurrences == 0 {
            throw ToolError.message("old_string not found in \(path). Read the file and match exactly.")
        }
        if occurrences > 1 {
            throw ToolError.message("old_string appears \(occurrences) times in \(path); add surrounding context to make it unique.")
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        try updated.data(using: .utf8)?.write(to: url)
        return "Replaced 1 occurrence in \(path)."
    }
}
