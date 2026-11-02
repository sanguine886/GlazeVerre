import Foundation

/// Agent loop configuration (spec §4.6). Defaults match the spec's guardrails.
public struct AgentLoopConfiguration: Sendable, Equatable {
    /// Model identifier handed to the provider (matches the provider config).
    public var model: String
    public var strategy: ApprovalStrategy = .alwaysAsk
    public var maxToolRounds: Int = 12
    /// Single tool-output clamp: spec §4.6 (≤ 8 KB).
    public var outputLimitBytes: Int = 8 * 1024

    public init(
        model: String,
        strategy: ApprovalStrategy = .alwaysAsk,
        maxToolRounds: Int = 12,
        outputLimitBytes: Int = 8 * 1024
    ) {
        self.model = model
        self.strategy = strategy
        self.maxToolRounds = maxToolRounds
        self.outputLimitBytes = outputLimitBytes
    }
}

/// Observable phase of the agent loop (spec §4.6: visible thinking state).
public enum AgentLoopPhase: Sendable, Equatable {
    case idle
    case thinking
    case awaitingApproval(AgentProposal)
    case executing
    case finished(text: String)
    case cancelledByUser
    case failed(AgentError)
}

/// The agent loop: model prop → human approves/rejects → tool runs → result
/// feeds back, until the model produces a final answer or the round budget or
/// kill switch ends it. `@MainActor` because the approval/execution hops
/// through UI-bound callbacks; the provider/host hops are async.
@MainActor
public final class AgentLoop {
    private let provider: any AIChatStreaming
    private let host: any HostCommandSession
    private let registry: AgentToolRegistry
    private let decider: any ApprovalDeciding
    private let auditLog: any AuditLogging
    private let killSwitch: AgentCancellationToken
    public let configuration: AgentLoopConfiguration

    private var history: [ChatMessage] = []
    private var phase: AgentLoopPhase = .idle
    private var roundCount = 0

    public init(
        provider: any AIChatStreaming,
        host: any HostCommandSession,
        registry: AgentToolRegistry,
        decider: any ApprovalDeciding,
        auditLog: any AuditLogging,
        configuration: AgentLoopConfiguration,
        killSwitch: AgentCancellationToken = AgentCancellationToken()
    ) {
        self.provider = provider
        self.host = host
        self.registry = registry
        self.decider = decider
        self.auditLog = auditLog
        self.killSwitch = killSwitch
        self.configuration = configuration
    }

    public func currentPhase() -> AgentLoopPhase {
        phase
    }

    /// Starts a task from a user prompt and host context. Runs until the model
    /// proposes an action (returns `.awaitingApproval`) or finishes answering.
    public func requestTurn(prompt: String, context: AgentContext) async throws -> AgentTurn {
        phase = .thinking
        history = []
        roundCount = 0
        let system = AgentContextBuilder.systemPrompt(tools: registry.definitions, context: context, approvedWorkingDir: context.host.workingPaths.first)
        history.append(ChatMessage(role: .system, content: system))
        history.append(ChatMessage(role: .user, content: prompt))
        return try await runModelTurn()
    }

    /// The user approved (optionally with an edited command). The proposal is
    /// re-classified before it runs — edits must face the classifier again
    /// (spec §4.6: no strategy combination bypasses dangerous-command review).
    public func continueAfterApproval(proposal: AgentProposal, editedCommand: String?) async throws -> AgentTurn {
        guard isPending(proposal) else {
            throw AgentError.badState("Approval passed but the proposal is no longer pending")
        }
        // Edit-reapproval: re-classify the edited command.
        if let edited = editedCommand, edited != proposal.commandText {
            let classification = DangerousCommandClassifier().classify(edited)
            if classification.verdict != .safe {
                // A dangerous/critical edit must go back for human review.
                let reProposal = AgentProposal(
                    toolCallID: proposal.toolCallID,
                    toolName: proposal.toolName,
                    arguments: proposal.arguments,
                    commandText: edited,
                    modelDeclaredSafe: proposal.modelDeclaredSafe,
                    classification: classification,
                    explanation: proposal.explanation
                )
                phase = .awaitingApproval(reProposal)
                return AgentTurn(text: nil, proposal: reProposal)
            }
        }

        let commandToRun = editedCommand ?? proposal.commandText
        phase = .executing
        let result = try await execute(proposal, command: commandToRun, editApproved: editedCommand != nil)
        history.append(ChatMessage(role: .tool, content: result.text, toolCallID: proposal.toolCallID))
        roundCount += 1
        return try await runModelTurn()
    }

    public func continueAfterRejection(proposal: AgentProposal) async throws -> AgentTurn {
        guard isPending(proposal) else {
            throw AgentError.badState("Rejection passed but the proposal is no longer pending")
        }
        await auditLog.record(AuditEntry(
            timestamp: Date(),
            toolName: proposal.toolName,
            commandText: proposal.commandText ?? "",
            resultSummary: "rejected by user",
            approver: "user",
            strategy: configuration.strategy,
            outcome: .rejected
        ))
        history.append(ChatMessage(role: .tool, content: "user rejected this action", toolCallID: proposal.toolCallID))
        roundCount += 1
        return try await runModelTurn()
    }

    /// Kill switch: cancels the in-flight provider request and any running tool.
    public func cancel() async {
        await killSwitch.cancel()
        phase = .cancelledByUser
    }

    public func cancelToken() -> AgentCancellationToken {
        killSwitch
    }

    // MARK: - Internal

    private func isPending(_ proposal: AgentProposal) -> Bool {
        if case let .awaitingApproval(p) = phase, p.toolCallID == proposal.toolCallID {
            return true
        }
        return false
    }

    private func runModelTurn() async throws -> AgentTurn {
        do {
            try await killSwitch.throwIfCancelled()
        } catch {
            phase = .cancelledByUser
            throw AgentError.cancelled
        }

        // The round budget is a hard stop: without it a model that keeps
        // proposing tools loops until the provider bills out.
        if roundCount > configuration.maxToolRounds {
            let message = "Stopped after \(configuration.maxToolRounds) tool rounds."
            phase = .finished(text: message)
            return AgentTurn(text: message, proposal: nil)
        }

        let request = ChatCompletionRequest(model: configuration.model, messages: history, tools: registry.definitions)
        let stream = try await provider.streamCompletion(request)
        var textPieces: [String] = []
        var toolCall: AssistantToolCall?

        do {
            for try await event in stream {
                switch event {
                case let .content(t):
                    textPieces.append(t)
                    if t.isEmpty {
                        continue
                    }
                case let .toolCall(delta):
                    // Fragment deltas concatenate into a single call.
                    toolCall = AssistantToolCall(id: delta.id, name: delta.name ?? "", argumentsJSON: delta.argumentsJSON)
                case let .toolCallComplete(delta):
                    toolCall = AssistantToolCall(id: delta.id, name: delta.name ?? "", argumentsJSON: delta.argumentsJSON)
                case .usage, .done:
                    break
                }
            }
        } catch {
            phase = .failed(.badState(error.localizedDescription))
            throw AgentError.badState(error.localizedDescription)
        }

        let text = textPieces.joined()
        phase = .thinking

        if let call = toolCall, !call.name.isEmpty {
            // The assistant turn that issued the tool call MUST be in the history
            // before its `tool` result is sent back, or the provider rejects the
            // next request with "tool result's tool id (…) not found".
            history.append(ChatMessage(role: .assistant, content: text, toolCalls: [call]))
            let proposal = try await makeProposal(from: call, text: text)
            phase = .awaitingApproval(proposal)
            return AgentTurn(text: text, proposal: proposal)
        }

        let answer = text.isEmpty ? "(no response)" : text
        history.append(ChatMessage(role: .assistant, content: answer))
        phase = .finished(text: answer)
        return AgentTurn(text: answer, proposal: nil)
    }

    private func makeProposal(from call: AssistantToolCall, text: String) async throws -> AgentProposal {
        let arguments = Self.parseArguments(call.argumentsJSON ?? "{}")
        // What will actually run on the host — the shell rendering of this tool.
        // The card shows it, the classifier judges it and the executor runs it.
        let commandText = AgentToolRegistry.shellCommand(for: call.name, arguments: arguments)
            ?? arguments["path"]?.stringValue
        let safe = arguments["safe_to_run"] == .boolean(true)
        let classification = DangerousCommandClassifier().classify(commandText ?? "")
        return AgentProposal(
            toolCallID: call.id,
            toolName: call.name,
            arguments: arguments,
            commandText: commandText,
            modelDeclaredSafe: safe,
            classification: classification,
            explanation: text.isEmpty ? nil : text
        )
    }

    private func execute(_ proposal: AgentProposal, command: String?, editApproved: Bool) async throws -> ToolResult {
        let decision = decider.decide(
            classification: proposal.classification,
            modelDeclaredSafe: proposal.modelDeclaredSafe,
            toolName: proposal.toolName,
            isReadonlyTool: Self.isReadonlyTool(proposal.toolName, registry: registry),
            commandText: command ?? "",
            strategy: configuration.strategy
        )

        // The decider already ran before the proposal was surfaced; a `deny`
        // (read-only mode refusing a write) is a hard stop here too.
        if case .deny = decision {
            await auditLog.record(AuditEntry(
                timestamp: Date(),
                toolName: proposal.toolName,
                commandText: command ?? "",
                resultSummary: "denied by read-only policy",
                approver: "auto",
                strategy: configuration.strategy,
                outcome: .denied
            ))
            throw AgentError.approvalDenied("Blocked by \(configuration.strategy.rawValue) policy")
        }

        guard let executor = registry.executor(for: proposal.toolName) else {
            throw AgentError.unknownToolCall(proposal.toolName)
        }

        let invocation = AgentToolInvocation(
            toolCallID: proposal.toolCallID,
            name: proposal.toolName,
            arguments: Self.merging(command: command, into: proposal.arguments)
        )
        let executed = try await executor.execute(invocation, cancelToken: cancelToken())
        // Spec §4.6: a single tool result is clamped before it goes back to the
        // model, so one `cat` of a big log cannot blow up the context.
        let result = Self.clamped(executed, limitBytes: configuration.outputLimitBytes)
        let outcome: AuditEntry.Outcome = editApproved ? .editedApproved : .userApproved
        await auditLog.record(AuditEntry(
            timestamp: Date(),
            toolName: proposal.toolName,
            commandText: command ?? "",
            resultSummary: result.text.prefix(200).description,
            approver: "user" + (editApproved ? "-edited" : ""),
            strategy: configuration.strategy,
            outcome: outcome
        ))
        return result
    }

    /// Hands the executor the command that was actually approved. Without this an
    /// edited command would be discarded and the model's original one would run.
    private static func merging(command: String?, into arguments: [String: JSONValue]) -> [String: JSONValue] {
        guard let command, !command.isEmpty else {
            return arguments
        }
        var merged = arguments
        merged["command"] = .string(command)
        return merged
    }

    private static func clamped(_ result: ToolResult, limitBytes: Int) -> ToolResult {
        let (text, truncated) = ToolResult.clampOutput(result.text, limitBytes: limitBytes)
        guard truncated else {
            return result
        }
        return ToolResult(
            toolCallID: result.toolCallID,
            text: text + "\n… output truncated at \(limitBytes) bytes",
            status: result.status,
            truncated: true
        )
    }

    private static func isReadonlyTool(_ name: String, registry: AgentToolRegistry) -> Bool {
        registry.definitions.first { $0.name == name }?.isReadonly ?? false
    }

    private static func parseArguments(_ json: String) -> [String: JSONValue] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(dict) = obj
        else {
            return [:]
        }
        return dict
    }
}
