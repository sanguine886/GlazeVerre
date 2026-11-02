@testable import AIAgent
import Foundation
import XCTest

/// Scripted chat provider for agent-loop tests (spec §6.5.2 fake injection).
actor FakeChatProvider: AIChatStreaming {
    /// Each entry is a scripted response; `toolCall` marks a tool proposal.
    struct Response: Sendable {
        var text: String
        var toolCall: AssistantToolCall?
    }

    private var script: [Response]
    private(set) var requests = 0
    /// The last request the loop sent, so tests can assert on the message chain.
    private(set) var lastRequest: ChatCompletionRequest?

    init(_ script: [Response]) {
        self.script = script
    }

    func streamCompletion(
        _ request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        lastRequest = request
        let script = script
        let index = requests
        let response = script[min(index, script.count - 1)]
        requests += 1
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.content(response.text))
            }
            if let call = response.toolCall {
                continuation.yield(.toolCallComplete(ChatToolCallDelta(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON ?? "{}")))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

/// Records what it was asked to run, so tests can assert the approved command
/// (not the model's original) reaches the host.
final class CapturingToolExecutor: AgentToolExecutor, @unchecked Sendable {
    private(set) var commands: [String] = []

    func execute(
        _ invocation: AgentToolInvocation,
        cancelToken _: AgentCancellationToken?
    ) async throws -> ToolResult {
        commands.append(invocation.arguments["command"]?.stringValue ?? "")
        return ToolResult(toolCallID: invocation.toolCallID, text: "captured", status: .success, truncated: false)
    }
}

/// Scripted host session (no network).
/// Scripted tool executor for the agent loop.
struct FakeToolExecutor: AgentToolExecutor, Sendable {
    var output: String

    func execute(
        _ invocation: AgentToolInvocation,
        cancelToken _: AgentCancellationToken?
    ) async throws -> ToolResult {
        ToolResult(toolCallID: invocation.toolCallID, text: output, status: .success, truncated: false)
    }
}

actor FakeHostSession: HostCommandSession {
    var runs: [String] = []
    var output: String
    var shouldThrow: Bool
    var cancelCalls = 0
    var connected = true

    init(output: String = "ok", shouldThrow: Bool = false) {
        self.output = output
        self.shouldThrow = shouldThrow
    }

    func run(command: String, timeout _: TimeInterval) async throws -> AsyncThrowingStream<String, Error> {
        try await Task.sleep(nanoseconds: 10_000_000)
        runs.append(command)
        if shouldThrow {
            throw AgentError.badState("host failed")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }

    func cancelCurrentCommand() async {
        cancelCalls += 1
    }

    func isRemoteConnected() async -> Bool {
        connected
    }
}

final class AgentLoopTests: XCTestCase {
    /// Bundles the loop fixture so `makeLoop` returns a single struct instead
    /// of a 5-tuple (which swiftlint's `large_tuple` rejects).
    private struct Fixture {
        let loop: AgentLoop
        let provider: FakeChatProvider
        let host: FakeHostSession
        let audit: InMemoryAuditLog
    }

    @MainActor
    private func makeLoop(
        script: [FakeChatProvider.Response],
        host: FakeHostSession = FakeHostSession(),
        strategy: ApprovalStrategy = .alwaysAsk,
        executor: any AgentToolExecutor = FakeToolExecutor(output: "fake output"),
        outputLimitBytes: Int = 8 * 1024
    ) -> Fixture {
        let provider = FakeChatProvider(script)
        var registry = AgentToolRegistry(definitions: AgentToolRegistry.defaultToolDefinitions)
        // Register a fake executor for run_command so the loop can execute it.
        registry.register(
            ToolDefinition(name: "run_command", description: "run a command", parameters: JSONSchemaBuilder.object(properties: [:]), isReadonly: false),
            executor: executor
        )
        let decider = ApprovalDecider()
        let audit = InMemoryAuditLog()
        let config = AgentLoopConfiguration(model: "test-model", strategy: strategy, outputLimitBytes: outputLimitBytes)
        let loop = AgentLoop(
            provider: provider,
            host: host,
            registry: registry,
            decider: decider,
            auditLog: audit,
            configuration: config
        )
        return Fixture(loop: loop, provider: provider, host: host, audit: audit)
    }

    @MainActor
    func testAlwaysAskSurfacesApprovalCard() async throws {
        let call = AssistantToolCall(id: "1", name: "run_command", argumentsJSON: #"{"command":"ls -la /tmp","safe_to_run":false}"#)
        let fixture = makeLoop(script: [.init(text: "let me list", toolCall: call)])
        let loop = fixture.loop
        let context = AgentContext(userPrompt: "list tmp", host: HostSummary(alias: "host", workingPaths: ["/tmp"]))
        let turn = try await loop.requestTurn(prompt: "list tmp", context: context)
        XCTAssertEqual(turn.proposal?.toolName, "run_command")
        XCTAssertEqual(turn.proposal?.classification.verdict, .safe)
    }

    @MainActor
    func testApproveThenToolRunsAndFinishes() async throws {
        let call = AssistantToolCall(id: "2", name: "run_command", argumentsJSON: #"{"command":"df -h","safe_to_run":true}"#)
        let fixture = makeLoop(
            script: [
                .init(text: "checking disk", toolCall: call),
                .init(text: "done: 1MB used", toolCall: nil),
            ],
            host: FakeHostSession(output: "1MB used")
        )
        let loop = fixture.loop
        try await loop.requestTurn(prompt: "disk", context: AgentContext(userPrompt: "disk", host: HostSummary(alias: "h", workingPaths: [])))
        let proposal = AgentProposal(
            toolCallID: "2",
            toolName: "run_command",
            arguments: ["command": .string("df -h"), "safe_to_run": .boolean(true)],
            commandText: "df -h",
            modelDeclaredSafe: true,
            classification: CommandClassification(verdict: .safe, matchedRule: nil),
            explanation: nil
        )
        try await loop.continueAfterApproval(proposal: proposal, editedCommand: nil)
        let audit = fixture.audit
        let entries = await audit.entries()
        XCTAssertEqual(entries.count, 1, "approved tool run must be recorded in audit")
        XCTAssertEqual(entries[0].outcome, .userApproved)
    }

    @MainActor
    func testEditedCommandIsReclassifiedBeforeRun() async throws {
        let call = AssistantToolCall(id: "3", name: "run_command", argumentsJSON: #"{"command":"ls","safe_to_run":true}"#)
        let fixture = makeLoop(
            script: [
                .init(text: "list", toolCall: call),
                .init(text: "blocked", toolCall: nil),
            ]
        )
        let loop = fixture.loop
        let host = fixture.host
        let first = try await loop.requestTurn(prompt: "show", context: AgentContext(userPrompt: "show", host: HostSummary(alias: "h", workingPaths: [])))
        guard let proposal = first.proposal else {
            return XCTFail("expected proposal")
        }
        // User edits `ls` into a dangerous `rm -rf /` — the loop must re-review.
        let next = try await loop.continueAfterApproval(proposal: proposal, editedCommand: "rm -rf /")
        XCTAssertNotNil(next.proposal, "dangerous edit must go back for human review")
        let runs = await host.runs
        XCTAssertTrue(runs.isEmpty, "dangerous edit must NOT execute")
    }

    @MainActor
    func testRejectThenModelContinues() async throws {
        let call = AssistantToolCall(id: "4", name: "run_command", argumentsJSON: #"{"command":"rm x","safe_to_run":true}"#)
        let fixture = makeLoop(
            script: [
                .init(text: "propose", toolCall: call),
                .init(text: "understood", toolCall: nil),
            ]
        )
        let loop = fixture.loop
        let host = fixture.host
        let audit = fixture.audit
        let first = try await loop.requestTurn(prompt: "help", context: AgentContext(userPrompt: "help", host: HostSummary(alias: "h", workingPaths: [])))
        guard let proposal = first.proposal else {
            return XCTFail("expected proposal")
        }
        let next = try await loop.continueAfterRejection(proposal: proposal)
        XCTAssertEqual(next.text, "understood")
        XCTAssertNil(next.proposal)
        let entries = await audit.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].outcome, .rejected)
        let runs = await host.runs
        XCTAssertTrue(runs.isEmpty)
    }

    @MainActor
    func testKillSwitchStopsExecution() async throws {
        let call = AssistantToolCall(id: "5", name: "run_command", argumentsJSON: #"{"command":"sleep 100","safe_to_run":false}"#)
        let fixture = makeLoop(
            script: [.init(text: "long", toolCall: call)],
            host: FakeHostSession(output: "never", shouldThrow: false)
        )
        let loop = fixture.loop
        let first = try await loop.requestTurn(prompt: "long", context: AgentContext(userPrompt: "long", host: HostSummary(alias: "h", workingPaths: [])))
        guard let proposal = first.proposal else {
            return XCTFail("expected proposal")
        }
        await loop.cancel()
        let phase = loop.currentPhase()
        XCTAssertEqual(phase, .cancelledByUser)
    }

    @MainActor
    func testDangerousCommandIsBlockedByEveryStrategy() async throws {
        let call = AssistantToolCall(id: "6", name: "run_command", argumentsJSON: #"{"command":"rm -rf /","safe_to_run":true}"#)
        for strategy in [ApprovalStrategy.alwaysAsk, .autoReview, .readOnly] {
            let fixture = makeLoop(
                script: [.init(text: "bad", toolCall: call)],
                strategy: strategy
            )
            let loop = fixture.loop
            let host = fixture.host
            let turn = try await loop.requestTurn(prompt: "go", context: AgentContext(userPrompt: "go", host: HostSummary(alias: "h", workingPaths: [])))
            XCTAssertEqual(turn.proposal?.classification.verdict, .dangerous, "strategy \(strategy) must classify rm -rf / as dangerous")
            let runs = await host.runs
            XCTAssertTrue(runs.isEmpty, "no strategy may run a critical command")
        }
    }

    /// Regression: the provider rejected the follow-up request with
    /// "tool result's tool id (…) not found" because the assistant turn that
    /// issued the tool call was missing from the history.
    @MainActor
    func testToolResultIsPrecededByItsAssistantToolCall() async throws {
        let call = AssistantToolCall(id: "chatcmpl-tool-9d84", name: "run_command", argumentsJSON: #"{"command":"uptime","safe_to_run":true}"#)
        let fixture = makeLoop(
            script: [
                .init(text: "checking", toolCall: call),
                .init(text: "all good", toolCall: nil),
            ]
        )
        let first = try await fixture.loop.requestTurn(
            prompt: "status",
            context: AgentContext(userPrompt: "status", host: HostSummary(alias: "h", workingPaths: []))
        )
        guard let proposal = first.proposal else {
            return XCTFail("expected proposal")
        }
        _ = try await fixture.loop.continueAfterApproval(proposal: proposal, editedCommand: nil)

        let messages = await fixture.provider.lastRequest?.messages ?? []
        guard let toolIndex = messages.firstIndex(where: { $0.role == .tool }) else {
            return XCTFail("tool result must be sent back to the model")
        }
        let assistantCalls = messages[..<toolIndex].filter { $0.role == .assistant }.flatMap(\.toolCalls)
        XCTAssertTrue(
            assistantCalls.contains { $0.id == messages[toolIndex].toolCallID },
            "the assistant tool_call must precede its tool result, or the provider returns HTTP 400"
        )
    }

    /// The command the human approved is the command that runs — an edit used to
    /// be re-classified and then silently dropped on the way to the executor.
    @MainActor
    func testApprovedEditRunsInsteadOfTheModelsCommand() async throws {
        let call = AssistantToolCall(id: "7", name: "run_command", argumentsJSON: #"{"command":"uptime","safe_to_run":true}"#)
        let executor = CapturingToolExecutor()
        let fixture = makeLoop(
            script: [
                .init(text: "checking", toolCall: call),
                .init(text: "done", toolCall: nil),
            ],
            executor: executor
        )
        let first = try await fixture.loop.requestTurn(
            prompt: "uptime",
            context: AgentContext(userPrompt: "uptime", host: HostSummary(alias: "h", workingPaths: []))
        )
        guard let proposal = first.proposal else {
            return XCTFail("expected proposal")
        }
        _ = try await fixture.loop.continueAfterApproval(proposal: proposal, editedCommand: "uptime -p")
        XCTAssertEqual(executor.commands, ["uptime -p"])
    }

    /// A tool without a `command` argument (`get_system_info`) must still reach
    /// the host as a real shell command — Linux has no `get_system_info`.
    @MainActor
    func testAbstractToolIsRenderedIntoAShellCommand() async throws {
        let call = AssistantToolCall(id: "8", name: "run_command", argumentsJSON: #"{"safe_to_run":true}"#)
        let fixture = makeLoop(script: [.init(text: "info", toolCall: call)])
        let turn = try await fixture.loop.requestTurn(
            prompt: "info",
            context: AgentContext(userPrompt: "info", host: HostSummary(alias: "h", workingPaths: []))
        )
        XCTAssertNil(turn.proposal?.commandText, "run_command without a command has nothing to run")

        let rendered = AgentToolRegistry.shellCommand(for: "get_system_info", arguments: ["safe_to_run": .boolean(true)])
        XCTAssertEqual(rendered, "uname -a; uptime; free -h; df -h /")
    }

    @MainActor
    func testToolOutputIsClampedBeforeItGoesBackToTheModel() async throws {
        let call = AssistantToolCall(id: "9", name: "run_command", argumentsJSON: #"{"command":"cat big.log","safe_to_run":true}"#)
        let fixture = makeLoop(
            script: [
                .init(text: "reading", toolCall: call),
                .init(text: "done", toolCall: nil),
            ],
            executor: FakeToolExecutor(output: String(repeating: "x", count: 40)),
            outputLimitBytes: 8
        )
        let first = try await fixture.loop.requestTurn(
            prompt: "log",
            context: AgentContext(userPrompt: "log", host: HostSummary(alias: "h", workingPaths: []))
        )
        guard let proposal = first.proposal else {
            return XCTFail("expected proposal")
        }
        _ = try await fixture.loop.continueAfterApproval(proposal: proposal, editedCommand: nil)
        let messages = await fixture.provider.lastRequest?.messages ?? []
        let content = messages.first { $0.role == .tool }?.content ?? ""
        XCTAssertTrue(content.hasPrefix("xxxxxxxx"), "the first 8 bytes survive")
        XCTAssertFalse(content.hasPrefix(String(repeating: "x", count: 9)), "everything past the limit is dropped")
        XCTAssertTrue(content.contains("truncated"), "the model is told the output was cut")
    }
}
