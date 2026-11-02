import Foundation

/// A compact, sanitized snapshot of the host context sent to the model.
///
/// Never carries secrets, IP addresses or connection details beyond what the
/// operator explicitly opted into (spec §6.4.2). `cwd` and the recent-output
/// buffer are the two fields the model reasons over.
public struct HostSummary: Sendable, Equatable {
    public let alias: String
    /// Paths/keys the agent was given permission to work in.
    public let workingPaths: [String]
    /// Not included by default; opt-in only (secrets/redirects stay local).
    public var includeHostname: Bool = false

    public init(alias: String, workingPaths: [String], includeHostname: Bool = false) {
        self.alias = alias
        self.workingPaths = workingPaths
        self.includeHostname = includeHostname
    }
}

/// The full context bundle for one agent task (spec §4.6). The builder fills
/// it; the model prompt is derived from it.
public struct AgentContext: Sendable, Equatable {
    public let userPrompt: String
    public let host: HostSummary
    /// Last N lines of the terminal scrollback, when the agent is attached to
    /// a live session (empty when not).
    public let recentOutput: [String]
    /// Aliases of every server the operator configured, so the model can name a
    /// target instead of the app silently picking one (真机需求: 助手需识别服务器列表).
    public let availableHosts: [String]

    public init(
        userPrompt: String,
        host: HostSummary,
        recentOutput: [String] = [],
        availableHosts: [String] = []
    ) {
        self.userPrompt = userPrompt
        self.host = host
        self.recentOutput = recentOutput
        self.availableHosts = availableHosts
    }
}

/// Builds the system prompt for the model from an `AgentContext`.
public enum AgentContextBuilder {
    /// System prompt that establishes the proposition-only boundary and the
    /// tool vocabulary. Keep it stable so provider caching works.
    public static func systemPrompt(
        tools: [ToolDefinition],
        context: AgentContext,
        approvedWorkingDir: String?
    ) -> String {
        var lines = [
            "You are GlazeVerre's remote-ops agent on host '\(context.host.alias)'.",
            "You may only PROPOSE actions; a human approves every execution.",
            "Every tool runs as a shell command over SSH on a Linux host, so use real",
            "shell commands (`run_command` with e.g. `uptime`, `df -h`) — tool names are",
            "not commands the host knows.",
            "Answer from your own knowledge and do NOT call a tool when the question",
            "does not need the server.",
            "Prefer read-only, idempotent operations. When running a command is unsafe,",
            "leave safe_to_run=false so the human can review.",
        ]
        if !context.availableHosts.isEmpty {
            lines.append("")
            lines.append("Servers the operator configured (pass `host` to target one, default '\(context.host.alias)'):")
            lines.append(contentsOf: context.availableHosts.map { "- \($0)" })
        }
        lines.append("")
        lines.append("Approved working directories:")
        for path in context.host.workingPaths {
            lines.append("- \(path)")
        }
        if let cwd = approvedWorkingDir {
            lines.append("(current directory: \(cwd))")
        }
        lines.append("")
        lines.append("Available tools:")
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)")
        }
        if !context.recentOutput.isEmpty {
            lines.append("")
            lines.append("Recent terminal output (last \(context.recentOutput.count) lines):")
            let shown = context.recentOutput.suffix(50)
            lines.append(contentsOf: shown.map { "  | \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
