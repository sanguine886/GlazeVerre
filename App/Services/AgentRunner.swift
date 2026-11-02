import AIAgent
import CoreSSH
import Foundation
import Observation
import OSLog
import Persistence

/// App-side agent runner (spec §4.6): wires a real `AgentLoop` onto a live
/// SSH host + the active AI provider, drives approvals/rejections, surfaces the
/// kill switch, and relays executed commands into a terminal ring buffer.
@MainActor
@Observable
final class AgentRunner {
    private static let logger = Logger(subsystem: "com.glazeverre.GlazeVerre", category: "agent")

    /// Where executed commands echo back (spec §4.6 double-view). A plain
    /// buffer suffices; the terminal layer may render it.
    private(set) var echoLines: [String] = []

    /// The most recent proposal awaiting approval, or nil.
    private(set) var pendingProposal: AgentProposal?

    /// Lifecycle label for the UI.
    private(set) var phaseLabel: String = "agent.idle"

    /// True while the loop is running (streaming/executing).
    private(set) var isRunning = false

    /// The live AgentLoop once connected, or nil.
    private(set) var loop: AgentLoop?

    /// The final assistant text of the most recent run (used by the chat
    /// transcript to show the agent's answer).
    private(set) var lastAgentText: String?

    /// Fired when a run completes with a final assistant answer, so a chat
    /// transcript can patch the agent's text in after approval.
    var onAgentAnswer: ((String) -> Void)?

    /// The host this runner is bound to, exposed so chat can reuse the session.
    private(set) var hostRecord: HostRecord?
    private(set) var hostManager: HostManager?

    /// Optional Sendable audit sink bound from the view.
    private var auditSink: (any AuditLogging)?

    /// Live sessions by host id. A tool may target any configured server
    /// (真机需求: 助手需能在某个服务器上执行命令), and consecutive turns reuse
    /// the connection instead of re-handshaking per command.
    private var sessions: [UUID: SSHSession] = [:]

    /// Bound from the view's environment audit manager.
    func setAudit(_ audit: (any AuditLogging)?) {
        auditSink = audit
    }

    /// Starts a run bound to `host` and `provider`. Returns an error message on
    /// failure, nil on success.
    func start(
        hostRecord: HostRecord,
        provider: AIProviderConfig,
        hostManager: HostManager,
        prompt: String,
        strategy: ApprovalStrategy = .alwaysAsk
    ) async -> String? {
        guard !isRunning else { return String(localized: "agent.alreadyRunning") }
        self.hostRecord = hostRecord
        self.hostManager = hostManager

        // Open (or reuse) the default target so the first tool call does not pay
        // for the handshake, and so an unreachable host fails loudly up front.
        let resolved = await resolveSession(alias: nil)
        guard let session = resolved.session else {
            return resolved.error
        }

        // Build the provider adapter from the stored key.
        guard let apiKey = try? KeychainStore().load(account: provider.apiKeyRef), !apiKey.isEmpty else {
            return String(localized: "agent.noKey")
        }
        let adapter = AIProviderAdapterFactory.make(kind: provider.kind, config: provider, apiKey: apiKey)

        // Wire the registry with real executors (SSH-backed) for the tools the model
        // may actually propose. Tools without an executor are not broadcast, so the
        // model never proposes something that would end in unknownToolCall.
        var registry = AgentToolRegistry(definitions: [])
        let sshExecutor = SSHCommandExecutor(resolve: { [weak self] alias in
            guard let self else { return (nil, "agent runner released") }
            return await resolveSession(alias: alias)
        })
        for definition in AgentToolRegistry.defaultToolDefinitions
            where !Self.isAppManagedTool(definition.name)
        {
            registry.register(definition, executor: sshExecutor)
        }

        let decider = ApprovalDecider()
        // Bridge the loop's audit records into SwiftData when the view bound a
        // store-based sink; otherwise keep an in-memory trail.
        let auditLogger = auditSink ?? InMemoryAuditLog()
        let loopConfig = AgentLoopConfiguration(model: provider.model, strategy: strategy)
        let loop = AgentLoop(
            provider: adapter,
            host: SSHSessionCommandAdapter(session: session),
            registry: registry,
            decider: decider,
            auditLog: auditLogger,
            configuration: loopConfig
        )
        self.loop = loop
        isRunning = true
        phaseLabel = "agent.thinking"

        // Only aliases go to the model: hostnames/IPs stay local (spec §6.4.2).
        let context = AgentContext(
            userPrompt: prompt,
            host: HostSummary(alias: hostRecord.name, workingPaths: []),
            availableHosts: hostManager.allHosts.map(\.name)
        )
        do {
            let turn = try await loop.requestTurn(prompt: prompt, context: context)
            surface(turn)
            return nil
        } catch {
            isRunning = false
            phaseLabel = "agent.failed"
            let message = error.localizedDescription
            echoLines.append("⚠️ " + message)
            return message
        }
    }

    /// Resolves a tool's optional `host` alias to a connected session, opening one
    /// on demand. Returns a message instead of a session when it cannot connect,
    /// so the model learns why rather than seeing an empty result.
    func resolveSession(alias: String?) async -> (session: SSHSession?, error: String?) {
        guard let hostManager else {
            return (nil, String(localized: "agent.noHost"))
        }
        let record: HostRecord? = if let alias, !alias.isEmpty {
            hostManager.allHosts.first { $0.name.caseInsensitiveCompare(alias) == .orderedSame }
        } else {
            hostRecord ?? hostManager.allHosts.first
        }
        guard let record else {
            return (nil, "unknown server '\(alias ?? "")'")
        }

        let session = sessions[record.id] ?? SSHSession()
        do {
            let config = try hostManager.openSession(for: record).1
            // `connect` is a no-op while already connected and reconnects a
            // dropped transport, so this doubles as the liveness check.
            try await session.connect(config: config, knownHosts: hostManager.knownHosts)
            hostManager.markConnected(record)
            sessions[record.id] = session
            return (session, nil)
        } catch {
            return (nil, "\(record.name): \(error.localizedDescription)")
        }
    }

    /// Runs the next model turn after the user decided on a proposal.
    func proceed(approve: Bool, editedCommand: String?) async -> String? {
        guard let loop, let proposal = pendingProposal else { return nil }
        // Consume the pending proposal BEFORE running the loop so a re-proposal
        // returned by an edit re-approval (dangerous edit) can be reassigned by
        // surface() instead of being cleared by a late defer.
        pendingProposal = nil
        let edit = (editedCommand?.isEmpty ?? true) ? nil : editedCommand
        if approve {
            echoLines.append("$ " + (edit ?? proposal.commandText ?? proposal.toolName))
        }
        do {
            let turn: AgentTurn = if approve {
                try await loop.continueAfterApproval(proposal: proposal, editedCommand: edit)
            } else {
                try await loop.continueAfterRejection(proposal: proposal)
            }
            surface(turn)
            return nil
        } catch {
            isRunning = false
            phaseLabel = "agent.failed"
            echoLines.append("⚠️ " + error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// Kill switch: aborts in-flight work (spec §4.6). Disconnects every pooled
    /// host so any running exec channel is aborted; the next run reconnects.
    func kill() async {
        await loop?.cancel()
        let stale = Array(sessions.values)
        sessions = [:]
        for session in stale {
            await session.disconnect()
        }
        isRunning = false
        phaseLabel = "agent.idle"
    }

    /// Surfaces a turn (proposal vs final answer).
    private func surface(_ turn: AgentTurn) {
        if let proposal = turn.proposal {
            pendingProposal = proposal
            phaseLabel = proposal.classification.verdict == .safe ? "agent.awaitingApproval" : "agent.dangerous"
        } else if let text = turn.text {
            lastAgentText = text
            echoLines.append("— " + text)
            phaseLabel = "agent.finished"
            isRunning = false
            onAgentAnswer?(text)
        }
    }

    /// Tools that are App-internal and get no broadcast executor.
    private static func isAppManagedTool(_ name: String) -> Bool {
        switch name {
        case "create_snippet", "run_snippet":
            true
        default:
            false
        }
    }
}

/// A real executor that runs the approved command over SSH, on whichever server
/// the tool named (`host` argument) or the session's default.
private struct SSHCommandExecutor: AgentToolExecutor, Sendable {
    /// Hops to the runner (MainActor) to resolve and connect the target host.
    let resolve: @Sendable (String?) async -> (session: SSHSession?, error: String?)

    func execute(_ invocation: AgentToolInvocation, cancelToken: AgentCancellationToken?) async throws -> ToolResult {
        let resolved = await resolve(invocation.arguments["host"]?.stringValue)
        guard let session = resolved.session else {
            let message = resolved.error ?? "no server available"
            return ToolResult(toolCallID: invocation.toolCallID, text: message, status: .failure(message), truncated: false)
        }
        // AgentLoop renders every tool into the shell command the human approved.
        let command = invocation.arguments["command"]?.stringValue ?? ""
        guard !command.isEmpty else {
            let message = "\(invocation.name) produced no command to run"
            return ToolResult(toolCallID: invocation.toolCallID, text: message, status: .failure(message), truncated: false)
        }
        // Kill switch must actually abort the in-flight exec. SSHSession exposes
        // no per-exec cancel, so we disconnect the transport (which aborts the
        // exec channel); the reconnect policy restores it before the next turn.
        var handlerID: UUID?
        if let cancelToken {
            handlerID = await cancelToken.register { [session] in
                await session.disconnect()
            }
        }
        defer {
            if let handlerID, let cancelToken {
                Task { await cancelToken.unregister(handlerID) }
            }
        }
        do {
            let result = try await session.run(command)
            return ToolResult(toolCallID: invocation.toolCallID, text: result.output, status: .success, truncated: false)
        } catch {
            let message = error.localizedDescription
            return ToolResult(toolCallID: invocation.toolCallID, text: message, status: .failure(message), truncated: false)
        }
    }
}
