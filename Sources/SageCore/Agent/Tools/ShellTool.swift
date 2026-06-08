import Foundation

struct ProcessResult: Sendable {
    var output: String
    var error: String
    var exitCode: Int32
}

/// Run a subprocess off the main actor and capture stdout/stderr. Used by the shell
/// and grep tools. Output is read fully before the process is reaped.
func runProcess(
    _ launchPath: String,
    _ arguments: [String],
    workingDirectory: URL? = nil
) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let wd = workingDirectory { process.currentDirectoryURL = wd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
            return
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        continuation.resume(returning: ProcessResult(
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        ))
    }
}

// MARK: - run_shell

public struct RunShellTool: Tool {
    public init() {}

    public var requiresApproval: Bool { true }

    public var spec: ToolSpec {
        ToolSpec(
            name: "run_shell",
            description: "Run a shell command in the project working directory and return its combined stdout/stderr and exit code. Requires user approval.",
            parameters: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to execute (run via /bin/zsh -lc)."],
                ],
                "required": ["command"],
            ]
        )
    }

    public func approvalPreview(arguments: [String: Any]) -> String {
        "$ " + (arguments["command"] as? String ?? "?")
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let command = arguments["command"] as? String, !command.isEmpty else {
            throw ToolError.missingArgument("command")
        }
        let result = try await runProcess(
            "/bin/zsh", ["-lc", command], workingDirectory: context.workingDirectory)

        var parts: [String] = []
        let combined = (result.output + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty { parts.append(combined) }
        parts.append("[exit code: \(result.exitCode)]")
        let text = parts.joined(separator: "\n")
        return text.count > 100_000 ? String(text.prefix(100_000)) + "\n… [truncated]" : text
    }
}
