import AIAgent
import GlassKit
import Persistence
import SwiftUI

/// P5 agent view (spec §4.6): drives `AgentRunner` against a live host,
/// surfaces approval cards with edit-after-approval, a floating kill switch,
/// and links to the audit trail.
struct AgentView: View {
    /// Shared with the chat transcript (same SSH pool + kill switch), owned by
    /// `AssistantView`.
    let runner: AgentRunner

    @Environment(AIProviderManager.self) private var providers
    @Environment(HostManager.self) private var hostManager
    @Environment(AuditManager.self) private var audit
    @State private var prompt = ""
    @State private var selectedHostID: UUID?
    @State private var strategy = ApprovalStrategy.alwaysAsk
    @State private var editedCommand = ""
    @State private var errorMessage: String?
    @State private var showAudit = false

    var body: some View {
        GlassEffectContainer(spacing: GlassSpacing.md) {
            VStack(spacing: 0) {
                controlsHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassSpacing.md) {
                        if let proposal = runner.pendingProposal {
                            approvalCard(for: proposal)
                        }
                        agentStatus
                        echoPanel
                    }
                    .padding(GlassSpacing.md)
                }
                promptComposer
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if runner.isRunning {
                Button("agent.kill", systemImage: "stop.circle.fill") {
                    Task { await runner.kill() }
                }
                .buttonStyle(.glassProminent)
                .tint(.glassDanger)
                .padding(GlassSpacing.lg)
            }
        }
        .sheet(isPresented: $showAudit) {
            AuditView()
        }
        .alert(Text("error.title"), isPresented: .init(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            runner.setAudit(audit.loggingSink())
        }
    }

    // MARK: - Controls

    private var controlsHeader: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.sm) {
            Picker("agent.host", selection: $selectedHostID) {
                Text("agent.host.none").tag(UUID?.none)
                ForEach(hostManager.allHosts) { host in
                    Text("\(host.name) (\(host.username)@\(host.hostname))").tag(Optional(host.id))
                }
            }
            .pickerStyle(.menu)

            Picker("agent.strategy", selection: $strategy) {
                ForEach([ApprovalStrategy.alwaysAsk, .autoReview, .readOnly], id: \.self) { strategy in
                    Text(strategyName(strategy)).tag(strategy)
                }
            }
            .pickerStyle(.segmented)

            if providers.activeProviderConfig == nil {
                Label("agent.noProvider", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.glassDanger)
            }
        }
        .padding(.horizontal, GlassSpacing.md)
        .padding(.vertical, GlassSpacing.sm)
        .background(Color.glassSurface.opacity(0.6))
    }

    // MARK: - Approval card

    private func approvalCard(for proposal: AgentProposal) -> some View {
        VStack(alignment: .leading, spacing: GlassSpacing.md) {
            ApprovalCard(
                proposal: ApprovalCard.Proposal(
                    titleKey: LocalizedStringKey("agent.proposal"),
                    command: proposal.commandText ?? proposal.toolName,
                    impactSummaryKey: proposal.explanation.map { LocalizedStringKey($0) }
                        ?? LocalizedStringKey("agent.proposal"),
                    isDangerous: proposal.classification.verdict != .safe
                ),
                onApprove: {
                    Task {
                        errorMessage = await runner.proceed(approve: true, editedCommand: editedCommand)
                        editedCommand = ""
                    }
                },
                onReject: {
                    Task {
                        errorMessage = await runner.proceed(approve: false, editedCommand: nil)
                    }
                }
            )

            TextField("agent.editCommand", text: $editedCommand)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var agentStatus: some View {
        HStack {
            Circle()
                .fill(runner.isRunning ? Color.glassAccent : Color.glassSecondaryText.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(runner.phaseLabel)
                .font(.footnote)
                .foregroundStyle(Color.glassSecondaryText)
            Spacer()
            Button("agent.audit", systemImage: "list.bullet.rectangle") {
                audit.refresh()
                showAudit = true
            }
            .font(.caption)
        }
    }

    private var echoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("agent.echo", systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(Color.glassSecondaryText)
            if runner.echoLines.isEmpty {
                Text("agent.echo.empty")
                    .font(.caption)
                    .foregroundStyle(Color.glassSecondaryText)
            } else {
                ForEach(runner.echoLines.suffix(30), id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.glassPrimaryText)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(GlassSpacing.md)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous))
    }

    private var promptComposer: some View {
        HStack {
            TextField("agent.prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1 ... 4)
            Button("agent.start", systemImage: "play.fill") {
                start()
            }
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runner.isRunning)
        }
        .padding(.horizontal, GlassSpacing.md)
        .padding(.vertical, GlassSpacing.sm)
        .background(
            Color.glassSurface,
            in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous)
        )
        .padding(.horizontal, GlassSpacing.md)
        .padding(.bottom, GlassSpacing.sm)
    }

    // MARK: - Actions

    private func start() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let provider = providers.activeProviderConfig else {
            errorMessage = String(localized: "agent.noProvider")
            return
        }
        // Default the target to the first configured server when none is explicitly
        // picked, so starting an agent run always has a reachable host.
        let hostID = selectedHostID ?? hostManager.allHosts.first?.id
        guard let host = hostManager.allHosts.first(where: { $0.id == hostID }) else {
            errorMessage = String(localized: "agent.noHost")
            return
        }
        prompt = ""
        Task {
            errorMessage = await runner.start(
                hostRecord: host,
                provider: provider,
                hostManager: hostManager,
                prompt: text,
                strategy: strategy
            )
        }
    }

    private func strategyName(_ strategy: ApprovalStrategy) -> String {
        switch strategy {
        case .alwaysAsk: String(localized: "agent.strategy.alwaysAsk")
        case .autoReview: String(localized: "agent.strategy.autoReview")
        case .readOnly: String(localized: "agent.strategy.readOnly")
        }
    }
}
