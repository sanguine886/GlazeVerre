import AIAgent
import GlassKit
import Persistence
import SwiftUI

/// AI assistant chat (spec §4.5): multi-session transcript, streaming turns,
/// Markdown rendering and a "what will be sent" preview.
struct AssistantView: View {
    @Environment(AIProviderManager.self) private var providers
    @Environment(HostManager.self) private var hostManager
    @Environment(ChatManager.self) private var chat
    @Environment(AuditManager.self) private var audit

    enum Mode: String, CaseIterable, Identifiable {
        case chat
        case agent
        var id: String {
            rawValue
        }
    }

    @State private var mode = Mode.chat
    @State private var draft = ""
    @State private var showPreview = false
    @FocusState private var inputFocused: Bool
    /// Agent engine shared by chat and the agent tab: one SSH session pool, one
    /// kill switch, one audit sink.
    @State private var agentRunner = AgentRunner()
    @State private var agentEditedCommand = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("assistant.mode", selection: $mode) {
                    Text("assistant.mode.chat").tag(Mode.chat)
                    Text("assistant.mode.agent").tag(Mode.agent)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, GlassSpacing.md)
                .padding(.top, GlassSpacing.xs)

                ZStack {
                    if mode == .chat {
                        content
                    } else {
                        AgentView(runner: agentRunner)
                    }
                }
            }
            .navigationTitle(Text("tab.assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.glassBackground.ignoresSafeArea())
            .accessibilityIdentifier("screen.assistant.heading")
            .task {
                hostManager.refresh()
                agentRunner.setAudit(audit.loggingSink())
                agentRunner.onAgentAnswer = { [chat] text in
                    Task { @MainActor in
                        chat.appendAgentText(text)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if mode == .chat {
                        sessionMenu
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Label(targetHostTitle, systemImage: "server.rack")
                        .font(.caption)
                        .foregroundStyle(Color.glassSecondaryText)
                }
            }
        }
    }

    /// The server the assistant acts on by default. No picker on purpose: the
    /// model sees every configured server in its context and names the one it
    /// wants (真机需求: 对话界面不需要切换主机).
    private var defaultHost: HostRecord? {
        hostManager.allHosts.first
    }

    private var targetHostTitle: String {
        guard let host = defaultHost else {
            return String(localized: "assistant.host.none")
        }
        let extras = hostManager.allHosts.count - 1
        return extras > 0 ? "\(host.name) +\(extras)" : host.name
    }

    private var sessionMenu: some View {
        Menu {
            Button("chat.new", systemImage: "square.and.pencil") {
                chat.newSession()
            }
            ForEach(chat.sessions, id: \.id) { session in
                Button {
                    chat.load(sessionID: session.id)
                } label: {
                    Text(session.title)
                }
            }
        } label: {
            Label(activeSessionTitle, systemImage: "text.bubble")
        }
    }

    private var activeSessionTitle: String {
        chat.sessions.first(where: { $0.id == chat.activeSessionID })?.title
            ?? String(localized: "chat.placeholder")
    }

    private var content: some View {
        GlassEffectContainer(spacing: GlassSpacing.md) {
            VStack(spacing: 0) {
                if providers.activeProviderConfig != nil {
                    transcript
                } else {
                    noProvider
                }
                composer
            }
        }
    }

    /// Placeholder when no provider is configured yet.
    private var noProvider: some View {
        VStack(spacing: GlassSpacing.md) {
            ContentUnavailableView(
                "chat.noProvider",
                systemImage: "brain.head.profile",
                description: Text("chat.noProviderHint")
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GlassSpacing.md) {
                    ForEach(chat.turns) { turn in
                        TurnBubble(turn: turn)
                    }
                    if let proposal = agentRunner.pendingProposal {
                        ApprovalCard(
                            proposal: ApprovalCard.Proposal(
                                titleKey: LocalizedStringKey("agent.proposal"),
                                command: proposal.commandText ?? proposal.toolName,
                                impactSummaryKey: proposal.explanation.map { LocalizedStringKey($0) }
                                    ?? LocalizedStringKey("agent.proposal"),
                                isDangerous: proposal.classification.verdict != .safe
                            ),
                            onApprove: {
                                // Read the edit BEFORE clearing it, or the user's
                                // edited command is thrown away.
                                let edited = agentEditedCommand
                                agentEditedCommand = ""
                                Task { _ = await agentRunner.proceed(approve: true, editedCommand: edited) }
                            },
                            onReject: {
                                Task { _ = await agentRunner.proceed(approve: false, editedCommand: nil) }
                            }
                        )
                        TextField("agent.editCommand", text: $agentEditedCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    // What the agent is doing on the server right now, so the
                    // transcript shows the operation and not just the answer.
                    if agentRunner.isRunning, !agentRunner.echoLines.isEmpty {
                        ForEach(agentRunner.echoLines.suffix(4), id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.glassSecondaryText)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    if chat.isStreaming {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("chat.streaming")
                                .font(.caption)
                                .foregroundStyle(Color.glassSecondaryText)
                            Spacer()
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(GlassSpacing.md)
            }
            .onChange(of: chat.turns.count) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat.isStreaming) {
                if chat.isStreaming {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: GlassSpacing.sm) {
            HStack {
                TextField("chat.input", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1 ... 6)
                    .focused($inputFocused)
                Button("chat.send", systemImage: "arrow.up.circle.fill") {
                    send()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isStreaming)
            }
            .padding(.horizontal, GlassSpacing.md)
            .padding(.vertical, GlassSpacing.sm)
            .background(
                Color.glassSurface,
                in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous)
            )

            HStack {
                Button("chat.preview", systemImage: "eye") {
                    showPreview = true
                }
                .font(.caption)
                Spacer()
                if chat.lastError != nil {
                    Text(chat.lastError!)
                        .font(.caption2)
                        .foregroundStyle(Color.glassDanger)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, GlassSpacing.sm)
        }
        .padding(.horizontal, GlassSpacing.md)
        .padding(.bottom, GlassSpacing.sm)
        .sheet(isPresented: $showPreview) {
            previewSheet
        }
    }

    private var previewSheet: some View {
        NavigationStack {
            ScrollView {
                Text("chat.previewIntro")
                    .font(.subheadline)
                    .foregroundStyle(Color.glassSecondaryText)
                Text(chat.systemPrompt())
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(Text("chat.preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { showPreview = false }
                }
            }
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let config = providers.activeProviderConfig else { return }
        draft = ""
        Task {
            _ = await chat.send(
                prompt,
                provider: config,
                agentHost: defaultHost,
                hostManager: defaultHost == nil ? nil : hostManager,
                agentRunner: defaultHost == nil ? nil : agentRunner
            )
        }
    }
}

/// One message bubble in the transcript.
private struct TurnBubble: View {
    let turn: ChatTurn

    var body: some View {
        HStack(alignment: .bottom) {
            if turn.role == .user {
                Spacer(minLength: 48)
            }
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 2) {
                Text(turn.role == .user ? "chat.you" : "chat.assistant")
                    .font(.caption2)
                    .foregroundStyle(Color.glassSecondaryText)
                bubble
            }
            .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant {
                Spacer(minLength: 48)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch turn.body {
        case let .text(text):
            Text(markdown(text))
                .textSelection(.enabled)
                .font(.body)
                .padding(GlassSpacing.md)
                .background(
                    turn.role == .user ? Color.glassAccent.opacity(0.18) : Color.glassSurface,
                    in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous)
                )
        case let .toolCall(json):
            VStack(alignment: .leading, spacing: 4) {
                Label("chat.tool", systemImage: "hammer")
                    .font(.caption)
                    .foregroundStyle(Color.glassSecondaryText)
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(GlassSpacing.md)
            .background(
                Color.glassSurface,
                in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous)
            )
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
