import AIAgent
import Foundation
import Observation
import OSLog
import Persistence

/// A single display row in a chat transcript. Wraps `ChatMessage` plus the
/// pending assistant stream so the view can render text + tool calls.
struct ChatTurn: Identifiable, Sendable {
    enum Body: Sendable {
        case text(String)
        case toolCall(String) // rendered JSON of the assistant tool call
    }

    var id = UUID()
    var role: ChatRole
    var body: Body
    var timestamp = Date()
}

/// App-side chat orchestration (spec §4.5): multi-session CRUD over
/// `ChatSessionStore`, streaming turns through the active provider, and a
/// "what will be sent" preview built from the system prompt.
@MainActor
@Observable
final class ChatManager {
    private static let logger = Logger(subsystem: "com.glazeverre.GlazeVerre", category: "chat")

    private let chatStore: ChatSessionStore
    private let secrets: SecretStoring
    private(set) var sessions: [ChatSessionRecord] = []
    private(set) var activeSessionID: UUID?
    private(set) var turns: [ChatTurn] = []
    /// Non-nil while a turn is streaming.
    private(set) var isStreaming = false
    private(set) var lastError: String?

    init(chatStore: ChatSessionStore, secrets: SecretStoring = KeychainStore()) {
        self.chatStore = chatStore
        self.secrets = secrets
    }

    // MARK: - Session CRUD

    func refresh() {
        sessions = (try? chatStore.all()) ?? []
        if activeSessionID == nil, let first = sessions.first {
            load(sessionID: first.id)
        }
    }

    func newSession(title: String = String(localized: "chat.newSession")) {
        let record = ChatSessionRecord(title: title)
        try? chatStore.add(record)
        refresh()
        load(sessionID: record.id)
    }

    func renameSession(id: UUID, to title: String) {
        guard let record = (try? chatStore.record(id: id)) ?? nil else { return }
        record.title = title
        try? chatStore.update(record)
        refresh()
    }

    func deleteSession(id: UUID) {
        try? chatStore.delete(id: id)
        if activeSessionID == id {
            activeSessionID = nil
            turns = []
        }
        refresh()
    }

    func load(sessionID: UUID) {
        activeSessionID = sessionID
        let record = (try? chatStore.record(id: sessionID)) ?? nil
        guard let data = record?.messagesJSON else {
            turns = []
            return
        }
        let stored = (try? JSONDecoder().decode([StoredMessage].self, from: data)) ?? []
        turns = stored.map { ChatTurn(role: $0.role, body: .text($0.text)) }
    }

    // MARK: - Sending

    /// Streams a user prompt through the active provider, appending turns, and
    /// persists the transcript. Agent-assisted mode: when a server is available
    /// the prompt routes through `AgentLoop` so the model can propose commands
    /// that execute on that server, and the result comes back into the
    /// conversation (真机需求: AI 助手自动操控服务器).
    func send(
        _ prompt: String,
        provider: AIProviderConfig,
        agentHost: HostRecord? = nil,
        hostManager: HostManager? = nil,
        agentRunner: AgentRunner? = nil
    ) async -> Bool {
        if let runner = agentRunner, let host = agentHost, let manager = hostManager {
            return await runAgent(prompt, provider: provider, host: host, manager: manager, runner: runner)
        }
        return await sendChatOnly(prompt, provider: provider)
    }

    /// Appends an agent's final answer into the active transcript (used by the
    /// shared AgentRunner callback after a tool round completes).
    func appendAgentText(_ text: String) {
        guard !text.isEmpty, let sessionID = activeSessionID else { return }
        let snapshot = [ChatTurn(role: .assistant, body: .text(text))]
        turns.append(contentsOf: snapshot)
        persist(sessionID: sessionID, appending: snapshot)
    }

    /// Routes one prompt through the agent loop against `host`. Tool proposals
    /// surface as approval cards on the view (`runner.pendingProposal`); the final
    /// answer arrives through `runner.onAgentAnswer` → `appendAgentText`.
    private func runAgent(
        _ prompt: String,
        provider: AIProviderConfig,
        host: HostRecord,
        manager: HostManager,
        runner: AgentRunner
    ) async -> Bool {
        guard let sessionID = activeSessionID else {
            newSession()
            return await runAgent(prompt, provider: provider, host: host, manager: manager, runner: runner)
        }
        // Persist the user's message right away: an agent turn can sit waiting for
        // approval for a long time, and the transcript must survive that.
        let userTurn = ChatTurn(role: .user, body: .text(prompt))
        turns.append(userTurn)
        persist(sessionID: sessionID, appending: [userTurn])

        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let message = await runner.start(
            hostRecord: host,
            provider: provider,
            hostManager: manager,
            prompt: prompt
        )
        if let message {
            lastError = message
            appendAgentText("⚠️ " + message)
            return false
        }
        return true
    }

    /// Plain-text streaming chat (no tools) — used when no server is configured.
    private func sendChatOnly(
        _ prompt: String,
        provider: AIProviderConfig
    ) async -> Bool {
        guard !isStreaming else { return false }
        guard let sessionID = activeSessionID else {
            newSession()
            return await sendChatOnly(prompt, provider: provider)
        }

        isStreaming = true
        lastError = nil

        let apiKey = resolveAPIKey(for: provider)
        guard !apiKey.isEmpty else {
            lastError = String(localized: "ai.send.noKey")
            isStreaming = false
            return false
        }

        let adapter = AIProviderAdapterFactory.make(kind: provider.kind, config: provider, apiKey: apiKey)
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt()),
        ]
        for turn in turns {
            messages.append(ChatMessage(role: turn.role, content: Self.text(of: turn.body)))
        }
        if !prompt.isEmpty {
            messages.append(ChatMessage(role: .user, content: prompt))
        }
        let request = ChatCompletionRequest(
            model: provider.model,
            messages: messages,
            tools: [],
            systemPrompt: systemPrompt(),
            stream: true
        )

        // Accumulate this turn's stream locally so switching sessions mid-stream
        // never writes a different session's transcript (spec §4.5 multi-session).
        var assistantText = ""
        var toolCalls: [String] = []
        // Append to self.turns only after the stream resolves, and only if the
        // user is still on the originating session.
        let originSessionID = sessionID
        do {
            let stream = try await adapter.streamCompletion(request)
            for try await event in stream {
                switch event {
                case let .content(text):
                    assistantText += text
                case let .toolCall(delta), let .toolCallComplete(delta):
                    toolCalls.append(delta.argumentsJSON)
                case .usage, .done:
                    break
                }
            }
            // The turns that belong to this send (for persistence).
            var turnSnapshot: [ChatTurn] = [ChatTurn(role: .user, body: .text(prompt))]
            for call in toolCalls {
                turnSnapshot.append(ChatTurn(role: .assistant, body: .toolCall(call)))
            }
            if !assistantText.isEmpty {
                turnSnapshot.append(ChatTurn(role: .assistant, body: .text(assistantText)))
            }
            if activeSessionID == originSessionID {
                turns.append(contentsOf: turnSnapshot)
            }
            persist(sessionID: originSessionID, appending: turnSnapshot)
            isStreaming = false
            return true
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("chat send failed: \(error.localizedDescription, privacy: .public)")
            isStreaming = false
            return false
        }
    }

    /// The system prompt for this turn, including host context when the agent
    /// is attached (spec §4.6). This is what the preview panel shows.
    func systemPrompt(hostContext: AgentContext? = nil) -> String {
        if let context = hostContext {
            return AgentContextBuilder.systemPrompt(
                tools: [],
                context: context,
                approvedWorkingDir: context.host.workingPaths.first
            )
        }
        return "You are GlazeVerre's AI assistant. Answer concisely with no markdown headers unless asked."
    }

    // MARK: - Persistence

    /// Appends a completed turn (the assets from `send`) to the session's stored
    /// transcript. Uses the passed snapshot so persisting never picks up a
    /// different session's in-memory `turns` mid-switch (spec §4.5 multi-session).
    private func persist(sessionID: UUID, appending newTurns: [ChatTurn]) {
        guard let record = (try? chatStore.record(id: sessionID)) ?? nil else { return }
        let existing = (try? JSONDecoder().decode([StoredMessage].self, from: record.messagesJSON)) ?? []
        let appended = existing + newTurns.map { StoredMessage(role: $0.role, text: Self.text(of: $0.body)) }
        record.messagesJSON = (try? JSONEncoder().encode(appended)) ?? Data()
        record.updatedAt = Date()
        try? chatStore.update(record)
        refresh()
    }

    private func resolveAPIKey(for provider: AIProviderConfig) -> String {
        (try? secrets.load(account: provider.apiKeyRef)) ?? ""
    }

    static func text(of body: ChatTurn.Body) -> String {
        switch body {
        case let .text(text): text
        case let .toolCall(json): json
        }
    }
}

/// Codable mirror of a message for JSON blob persistence.
private struct StoredMessage: Codable, Sendable {
    var role: ChatRole
    var text: String
}
