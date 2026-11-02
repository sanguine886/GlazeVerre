/// A concrete tool call proposed by the model.
public struct AgentToolInvocation: Sendable {
    public let toolCallID: String
    public let name: String
    public let arguments: [String: JSONValue]

    public init(toolCallID: String, name: String, arguments: [String: JSONValue]) {
        self.toolCallID = toolCallID
        self.name = name
        self.arguments = arguments
    }
}

/// The terminal state of a single tool run.
public enum ToolResultStatus: Sendable, Equatable {
    case success
    case failure(String)
    case cancelled
}

/// The output of a tool execution handed back to the model loop and the
/// audit trail.
public struct ToolResult: Sendable {
    public let toolCallID: String
    public let text: String
    public let status: ToolResultStatus
    public let truncated: Bool

    public init(toolCallID: String, text: String, status: ToolResultStatus, truncated: Bool) {
        self.toolCallID = toolCallID
        self.text = text
        self.status = status
        self.truncated = truncated
    }

    /// Clamps `text` to `limitBytes` and reports whether it was truncated.
    ///
    /// A cut that would split a UTF-8 sequence is backed off so the result
    /// never ends mid-codepoint.
    public static func clampOutput(_ text: String, limitBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limitBytes else {
            return (text, false)
        }
        // Take the first `limitBytes` bytes, then back off until the prefix is
        // valid UTF-8 (never split a multi-byte character).
        var slice = text.utf8.prefix(limitBytes)
        while String(bytes: slice, encoding: .utf8) == nil {
            slice = slice.dropLast()
        }
        return (String(bytes: slice, encoding: .utf8) ?? "", true)
    }
}

/// Runs a single tool for the agent loop.
public protocol AgentToolExecutor: Sendable {
    func execute(
        _ invocation: AgentToolInvocation,
        cancelToken: AgentCancellationToken?
    ) async throws -> ToolResult
}

/// Name-addressable registry of tool definitions and executors.
///
/// `ToolDefinition` and `JSONValue` are provided by the shared tool model
/// (spec §2.2) so this registry stays decoupled from P4 message types while
/// reusing the same schema vocabulary.
public struct AgentToolRegistry: Sendable {
    public private(set) var definitions: [ToolDefinition]
    private var executors: [String: any AgentToolExecutor]

    public init(definitions: [ToolDefinition] = [], executors: [String: any AgentToolExecutor] = [:]) {
        self.definitions = definitions
        self.executors = executors
    }

    /// The seven built-in tools every agent session offers.
    ///
    /// Every definition carries a `safe_to_run` boolean with the same guidance
    /// text; `isReadonly` mirrors the tool's intrinsic read/write nature so
    /// `safe_to_run` (a per-invocation claim by the model) stays a separate
    /// dimension.
    public static let defaultToolDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_command",
            description: "Run a shell command on the connected host.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": propertySchema(
                        type: "string",
                        description: "The shell command to execute."
                    ),
                    "timeout_s": propertySchema(type: "integer", description: "Timeout in seconds."),
                    "host": hostProperty(),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([.string("command")]),
            ]),
            isReadonly: false
        ),
        ToolDefinition(
            name: "read_file",
            description: "Read a file from the connected host.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": propertySchema(type: "string", description: "Absolute path of the file to read."),
                    "host": hostProperty(),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([.string("path")]),
            ]),
            isReadonly: true
        ),
        ToolDefinition(
            name: "write_file",
            description: "Write or append content to a file on the connected host.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": propertySchema(type: "string", description: "Absolute path of the file to write."),
                    "content": propertySchema(type: "string", description: "Full content to write."),
                    "host": hostProperty(),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([.string("path"), .string("content")]),
            ]),
            isReadonly: false
        ),
        ToolDefinition(
            name: "list_dir",
            description: "List the entries of a directory on the connected host.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": propertySchema(type: "string", description: "Absolute path of the directory to list."),
                    "host": hostProperty(),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([.string("path")]),
            ]),
            isReadonly: true
        ),
        ToolDefinition(
            name: "get_system_info",
            description: "Return basic information about the connected host "
                + "(runs uname/uptime/free/df over SSH).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "host": hostProperty(),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([]),
            ]),
            isReadonly: true
        ),
        ToolDefinition(
            name: "create_snippet",
            description: "Create a reusable snippet in the library.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": propertySchema(type: "string", description: "Unique snippet name."),
                    "script": propertySchema(type: "string", description: "Script content."),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([.string("name"), .string("script")]),
            ]),
            isReadonly: false
        ),
        ToolDefinition(
            name: "run_snippet",
            description: "Run a stored snippet on the connected host.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": propertySchema(type: "string", description: "Snippet name to run."),
                    "target": propertySchema(type: "string", description: "Optional target host override."),
                    "safe_to_run": safeToRunProperty(),
                ]),
                "required": .array([.string("name")]),
            ]),
            isReadonly: false
        ),
    ]

    public mutating func register(_ tool: ToolDefinition, executor: any AgentToolExecutor) {
        definitions.removeAll { $0.name == tool.name }
        definitions.append(tool)
        executors[tool.name] = executor
    }

    public func executor(for name: String) -> (any AgentToolExecutor)? {
        executors[name]
    }

    /// Renders a tool invocation into the shell command that actually runs on the
    /// host. The model proposes abstract tools (`read_file`, `get_system_info`),
    /// but a Linux box only speaks shell — one renderer keeps the approval card,
    /// the dangerous-command classifier and the executor looking at the very same
    /// text, so what a human approves is what runs.
    ///
    /// Returns nil for app-managed tools (snippets) that never touch the shell.
    /// `write_file` passes its payload as DATA (`printf '%s' '<content>'`),
    /// never as shell source: a heredoc would let a payload that contains the
    /// delimiter line run as commands, and `printf` with a quoted argument
    /// keeps the bytes exactly as the model wrote them.
    public static func shellCommand(for name: String, arguments: [String: JSONValue]) -> String? {
        let path = arguments["path"]?.stringValue
        switch name {
        case "run_command":
            return arguments["command"]?.stringValue
        case "read_file":
            return path.map { "cat -- \(singleQuoted($0))" }
        case "list_dir":
            return path.map { "ls -la -- \(singleQuoted($0))" }
        case "write_file":
            guard let path, let content = arguments["content"]?.stringValue else {
                return nil
            }
            return "printf '%s' \(singleQuoted(content)) > \(singleQuoted(path))"
        case "get_system_info":
            return "uname -a; uptime; free -h; df -h /"
        default:
            return nil
        }
    }

    /// POSIX single-quoting, so a path can never break out of the command it is
    /// embedded in (`it's` → `'it'\''s'`).
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func propertySchema(type: String, description: String) -> JSONValue {
        .object([
            "type": .string(type),
            "description": .string(description),
        ])
    }

    private static func safeToRunProperty() -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(
                "Set true only when running this action now is safe: read-only, "
                    + "idempotent, or fully reversible. When in doubt, set false so the "
                    + "user can review it."
            ),
        ])
    }

    /// Optional target-server alias. The operator may have several servers
    /// configured; naming one here routes the tool to that host instead of the
    /// session's default (spec §4.6 host context).
    private static func hostProperty() -> JSONValue {
        propertySchema(
            type: "string",
            description: "Optional server alias to run this on. Omit to use the current host."
        )
    }
}
