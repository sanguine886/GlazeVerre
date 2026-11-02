import Charts
import CoreSSH
import GlassKit
import Persistence
import SwiftUI

/// Server detail screen (tab1 click target): connects to the host and shows the
/// four headline metrics with trend sparklines (负载 / 内存 / 网络 / 磁盘 per
/// maidkit's dashboard), the rest in a collapsible disclosure (maidkit-style).
struct ServerDetailView: View {
    let record: HostRecord

    @Environment(HostManager.self) private var manager
    @State private var session: SSHSession?
    @State private var metrics: [ServerMetrics] = []
    @State private var pendingFlow: ConnectFlow?
    @State private var errorMessage: String?
    @State private var isCollecting = false

    var body: some View {
        ScrollView {
            VStack(spacing: GlassSpacing.md) {
                statusHeader
                if metrics.isEmpty {
                    ContentUnavailableView(
                        "server.detail.loading",
                        systemImage: "gauge.with.dots.needle.50percent",
                        description: Text("server.detail.loadingHint")
                    )
                } else {
                    headlineMetrics
                    detailDisclosure
                }
            }
            .padding(GlassSpacing.md)
        }
        .background(Color.glassBackground.ignoresSafeArea())
        .navigationTitle(Text(record.name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await openAndCollect() }
        .sheet(item: $pendingFlow) { flow in
            FingerprintConfirmView(kind: flow.kind) { decision in
                handleFingerprintDecision(decision, flow: flow)
            }
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
        .onDisappear {
            isCollecting = false
            let stale = session
            session = nil
            if let stale {
                Task { await stale.disconnect() }
            }
        }
    }

    // MARK: - Header

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(isCollecting ? Color.glassAccent : Color.glassSecondaryText.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(isCollecting ? "server.detail.live" : "server.detail.standby")
                .font(.subheadline)
                .foregroundStyle(Color.glassSecondaryText)
            Spacer()
            Text("\(record.username)@\(record.hostname):\(record.port)")
                .font(.glassMono(13))
                .foregroundStyle(Color.glassSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(GlassSpacing.md)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous))
    }

    // MARK: - Headline metrics (4 cards with sparklines)

    private var headlineMetrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: GlassSpacing.md) {
            MetricCard(
                title: "server.metric.load",
                value: String(format: "%.2f", metrics.last?.load1 ?? 0),
                unit: "",
                points: metrics.map { CGFloat($0.load1) }
            )
            MetricCard(
                title: "server.metric.memory",
                value: String(format: "%.0f%%", metrics.last?.memoryPercent ?? 0),
                unit: "",
                points: metrics.map { CGFloat($0.memoryPercent) }
            )
            MetricCard(
                title: "server.metric.network",
                value: Self.byteRate(metrics.last?.networkRxDelta ?? 0),
                unit: "",
                points: metrics.prefix(metrics.count).map { CGFloat($0.networkRxDelta) }
            )
            MetricCard(
                title: "server.metric.disk",
                value: String(format: "%.0f%%", metrics.last?.diskPercent ?? 0),
                unit: "",
                points: metrics.map { CGFloat($0.diskPercent) }
            )
        }
    }

    // MARK: - Collapsible detail (其余指标下拉收纳)

    private var detailDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: GlassSpacing.sm) {
                detailRow("server.detail.uptime", Self.uptimeText(metrics.last?.uptimeSeconds ?? 0))
                detailRow("server.detail.rxRate", Self.byteRate(metrics.last?.networkRxDelta ?? 0))
                detailRow("server.detail.txRate", Self.byteRate(metrics.last?.networkTxDelta ?? 0))
                detailRow("server.detail.memoryUsed", Self.bytes(metrics.last?.memoryUsed ?? 0))
                detailRow("server.detail.memoryTotal", Self.bytes(metrics.last?.memoryTotal ?? 0))
                detailRow("server.detail.diskUsed", Self.bytes(metrics.last?.diskUsed ?? 0))
                detailRow("server.detail.diskTotal", Self.bytes(metrics.last?.diskTotal ?? 0))
            }
            .padding(.top, GlassSpacing.sm)
        } label: {
            Label("server.detail.more", systemImage: "list.bullet.rectangle")
                .font(.subheadline)
                .foregroundStyle(Color.glassPrimaryText)
        }
        .padding(GlassSpacing.md)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous))
    }

    private func detailRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key).font(.subheadline).foregroundStyle(Color.glassSecondaryText)
            Spacer()
            Text(value).font(.glassMono(13)).foregroundStyle(Color.glassPrimaryText)
        }
    }

    // MARK: - Collection loop

    private func openAndCollect() async {
        // Show the last known state immediately; the live loop extends it.
        metrics = ServerMetricsCache.shared.history(for: record.id)
        guard session == nil, !isCollecting else { return }
        let (freshSession, config): (SSHSession, SSHHostConfig)
        do {
            (freshSession, config) = try manager.openSession(for: record)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            try await freshSession.connect(config: config, knownHosts: manager.knownHosts)
            manager.markConnected(record)
            session = freshSession
            isCollecting = true
        } catch let error as SSHError {
            switch error {
            case let .hostKeyUnknown(fingerprint):
                pendingFlow = ConnectFlow(
                    record: record, session: freshSession, config: config, kind: .new(fingerprint)
                )
            case let .hostKeyChanged(pinned, presented):
                pendingFlow = ConnectFlow(
                    record: record, session: freshSession, config: config,
                    kind: .changed(pinned: pinned, presented: presented)
                )
            default:
                errorMessage = error.localizedDescription
            }
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        await collect(on: freshSession)
    }

    /// The 3-second sampling loop, shared by the direct path and the
    /// trust-the-fingerprint path (which used to flip the live indicator on
    /// without ever sampling).
    private func collect(on session: SSHSession) async {
        var sampler = ServerMetricSampler(session: session)
        while isCollecting {
            if let snap = try? await sampler.sample() {
                metrics = ServerMetricsCache.shared.append(snap, for: record.id)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func handleFingerprintDecision(_ decision: Bool, flow: ConnectFlow) {
        guard decision else {
            Task { await flow.session.disconnect() }
            pendingFlow = nil
            return
        }
        Task {
            switch flow.kind {
            case let .new(fingerprint):
                manager.knownHosts.trust(hostIdentifier: flow.config.hostIdentifier, fingerprint: fingerprint)
            case let .changed(_, changed):
                manager.knownHosts.repin(hostIdentifier: flow.config.hostIdentifier, fingerprint: changed)
            }
            do {
                try await flow.session.connect(config: flow.config, knownHosts: manager.knownHosts)
                manager.markConnected(flow.record)
                session = flow.session
                pendingFlow = nil
                isCollecting = true
                await collect(on: flow.session)
            } catch {
                pendingFlow = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Formatters

    static func byteRate(_ bytesPerSec: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .file) + "/s"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func uptimeText(_ seconds: UInt64) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 {
            return String(format: "%dd %dh %dm", d, h, m)
        }
        return String(format: "%dh %dm", h, m)
    }
}

/// A small headline metric card with a Swift Charts sparkline.
private struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let unit: String
    let points: [CGFloat]

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.glassSecondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.glassPrimaryText)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Color.glassSecondaryText)
            }
            sparkline
                .frame(height: 44)
        }
        .padding(GlassSpacing.md)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: GlassSpacing.lg, style: .continuous))
    }

    /// A lightweight polyline sparkline (system `Path`) — runs on every iOS
    /// version and stays dependency-free.
    private var sparkline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = points.max() ?? 1
            let step = w / CGFloat(max(points.count - 1, 1))
            ZStack {
                if points.count >= 2 {
                    Path { path in
                        for (idx, p) in points.enumerated() {
                            let x = CGFloat(idx) * step
                            let y = h - (CGFloat(p) / CGFloat(maxV) * h)
                            if idx == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.glassAccent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                } else {
                    Rectangle()
                        .fill(Color.glassSurface.opacity(0.3))
                }
            }
        }
    }
}
