import CoreSSH
import GlassKit
import Persistence
import SwiftUI
import TerminalKit
import UIKit

/// Full terminal screen (spec P2): SwiftTerm view bridged to the SSH PTY,
/// extension keyboard bar, glass session tabs, tmux attach hint.
struct TerminalScreenView: View {
    let record: HostRecord

    @Environment(HostManager.self) private var manager
    @State private var prefs = TerminalPreferences.shared
    @State private var terminalSession: TerminalSession?
    @State private var tabs = SessionTabsModel()
    @State private var pendingFlow: ConnectFlow?
    @State private var errorMessage: String?
    @State private var showTmuxHint = false
    @State private var isOpening = false
    /// Session/config of the attempt awaiting a fingerprint decision.
    @State private var pendingSession: SSHSession?
    @State private var pendingConfig: SSHHostConfig?
    /// The live SSH session backing the terminal. Held here so closing the tab
    /// or leaving the screen actually disconnects the remote shell/PTY instead
    /// of leaking it (spec §4.2 lifecycle).
    @State private var session: SSHSession?

    var body: some View {
        VStack(spacing: 0) {
            if let terminalSession {
                TerminalViewWrapper(session: terminalSession)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                openingState
            }
            if !tabs.tabs.isEmpty {
                TerminalTabBar(model: tabs) { id in
                    closeSession(id: id)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(Text(record.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                ExtensionKeyboardBar(layout: .default) { text in
                    terminalSession?.send(text)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("terminal.newSession", systemImage: "plus") {
                        openNewSession()
                    }
                    Button("terminal.disconnect", systemImage: "bolt.slash", role: .destructive) {
                        disconnectAll()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { openFirstSession() }
        .onDisappear {
            terminalSession?.stop()
            terminalSession = nil
            let stale = session
            session = nil
            if let stale {
                Task { await stale.disconnect() }
            }
        }
        .sheet(item: $pendingFlow) { flow in
            FingerprintConfirmView(kind: flow.kind) { decision in
                handleFingerprintDecision(decision, flow: flow)
            }
        }
        .alert(Text("tmux.detected.title"), isPresented: $showTmuxHint) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("tmux.detected.body")
        }
        .alert(
            Text("error.title"),
            isPresented: .init(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var openingState: some View {
        VStack(spacing: GlassSpacing.md) {
            if isOpening {
                ProgressView()
                Text("terminal.connecting")
                    .font(.footnote)
                    .foregroundStyle(Color.glassSecondaryText)
            } else {
                Button("terminal.reconnect", systemImage: "arrow.clockwise") {
                    openFirstSession()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sessions

    private func openFirstSession() {
        guard terminalSession == nil else { return }
        openNewSession()
    }

    private func openNewSession() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                let (session, config) = try manager.openSession(for: record)
                try await startShell(session: session, config: config)
            } catch let error as SSHError {
                switch error {
                case let .hostKeyUnknown(fingerprint):
                    queueFingerprintFlow(.new(fingerprint))
                case let .hostKeyChanged(pinned, presented):
                    queueFingerprintFlow(.changed(pinned: pinned, presented: presented))
                default:
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func queueFingerprintFlow(_ kind: FingerprintFlowKind) {
        guard let pendingSession, let pendingConfig else {
            errorMessage = String(localized: "error.title")
            return
        }
        pendingFlow = ConnectFlow(record: record, session: pendingSession, config: pendingConfig, kind: kind)
    }

    private func startShell(session: SSHSession, config: SSHHostConfig) async throws {
        pendingSession = session
        pendingConfig = config
        try await session.connect(config: config, knownHosts: manager.knownHosts)
        manager.markConnected(record)
        try await attachShell(session)
    }

    private func attachShell(_ session: SSHSession) async throws {
        // A conventional 80x24 PTY; SwiftTerm reports the real column count for
        // the phone on its first layout pass and TerminalSession forwards it as a
        // window-change, so the remote reflows to the actual screen width.
        let shell = try await session.requestShell(cols: 80, rows: 24)
        let terminal = TerminalSession(
            shell: shell,
            fontName: prefs.fontName,
            fontSize: prefs.fontSize,
            theme: prefs.theme
        )
        terminal.onTmuxDetected = { showTmuxHint = true }
        terminalSession = terminal
        self.session = session
        _ = tabs.add(title: record.name)
    }

    private func handleFingerprintDecision(_ decision: Bool, flow: ConnectFlow) {
        pendingFlow = nil
        guard decision else { return }
        Task {
            do {
                switch flow.kind {
                case let .new(fingerprint):
                    manager.knownHosts.trust(hostIdentifier: flow.config.hostIdentifier, fingerprint: fingerprint)
                case let .changed(_, changed):
                    manager.knownHosts.repin(hostIdentifier: flow.config.hostIdentifier, fingerprint: changed)
                }
                try await flow.session.connect(config: flow.config, knownHosts: manager.knownHosts)
                manager.markConnected(flow.record)
                try await attachShell(flow.session)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func closeSession(id: UUID) {
        tabs.close(id: id)
        if tabs.tabs.isEmpty {
            terminalSession?.stop()
            terminalSession = nil
            Task { await session?.disconnect() }
            session = nil
        }
    }

    private func disconnectAll() {
        terminalSession?.stop()
        terminalSession = nil
        let stale = session
        session = nil
        if let stale {
            Task { await stale.disconnect() }
        }
        tabs = SessionTabsModel()
    }
}

/// UIViewRepresentable bridge for SwiftTerm's TerminalView.
private struct TerminalViewWrapper: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context _: Context) -> UIView {
        let host = TerminalHostView()
        host.backgroundColor = .black
        host.attach(session)
        return host
    }

    func updateUIView(_ container: UIView, context _: Context) {
        guard let host = container as? TerminalHostView else { return }
        host.attach(session)
    }

    /// Take exactly the size SwiftUI proposes. Without this the representable is
    /// measured through Auto Layout, and SwiftTerm's intrinsic content width
    /// (columns × cell width) makes the CLI wider than the phone (真机验收:
    /// 终端宽度大于屏幕).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView _: UIView, context _: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

/// Host UIView that owns a SwiftTerm terminal, keeps it exactly its own size,
/// takes keyboard focus, and pinch-zooms the font.
///
/// Frame-based layout on purpose: Auto Layout would let the terminal's intrinsic
/// content size propagate outwards and overflow the screen.
private final class TerminalHostView: UIView {
    private var session: TerminalSession?
    private var terminalView: TerminalView? {
        session?.terminalView
    }

    func attach(_ session: TerminalSession) {
        if self.session === session {
            return
        }
        self.session?.terminalView.removeFromSuperview()
        self.session = session
        let terminal = session.terminalView
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.frame = bounds
        addSubview(terminal)
        installGestures(on: terminal)
        setNeedsLayout()
        _ = terminal.becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // SwiftTerm recomputes its columns/rows from this frame and reports the
        // new size through TerminalViewDelegate → the remote PTY is resized.
        terminalView?.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            _ = terminalView?.becomeFirstResponder()
        }
    }

    private func installGestures(on terminal: TerminalView) {
        let focus = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap))
        focus.cancelsTouchesInView = false
        terminal.addGestureRecognizer(focus)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        terminal.addGestureRecognizer(pinch)
    }

    /// Raises the keyboard for the terminal — without a first responder nothing
    /// typed reaches the shell (真机验收: 键盘无法输入到 CLI).
    @objc private func handleFocusTap() {
        _ = terminalView?.becomeFirstResponder()
    }

    /// Pinch to change the font size (the terminal reflows, so this is how you
    /// fit more columns on a phone).
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed, let session else { return }
        let step = gesture.scale > 1.08 ? 1 : (gesture.scale < 0.92 ? -1 : 0)
        guard step != 0 else { return }
        session.setFontSize(session.currentFontSize + step)
        gesture.scale = 1
    }
}
